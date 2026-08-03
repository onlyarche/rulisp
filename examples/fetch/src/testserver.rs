//! A loopback HTTP/1.1 server, hand-rolled on tokio, so the test suite is
//! hermetic — no network, no CI flakiness, and exact control over the wire
//! bytes (obs-text header values, duplicate headers, missing Content-Length)
//! that a real server or a client library would normalise away.
//!
//! Endpoints:
//!   /bytes/N          N bytes of 'x', with Content-Length
//!   /no-length/N      N bytes, chunked (no Content-Length — the hostile
//!                     case for a body cap)
//!   /drip/N/MS        N bytes, one per MS milliseconds, chunked
//!   /delay/MS         empty 200 after MS milliseconds
//!   /status/N         status N
//!   /dup-headers      two Set-Cookie headers, in a fixed order
//!   /obs-text         a Content-Disposition value carrying a raw 0xE9 byte
//!   /echo-headers     the request's header block, verbatim, as the body

use std::io;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// Accept loop. The listener is bound SYNCHRONOUSLY by the caller so that
/// starting the server needs no wait at all (BOUNDARY §7: exports don't
/// block).
pub async fn serve_loop(listener: TcpListener) {
    loop {
        match listener.accept().await {
            Ok((sock, _)) => {
                tokio::spawn(async move {
                    let _ = serve(sock).await;
                });
            }
            Err(_) => break,
        }
    }
}

async fn read_request(sock: &mut TcpStream) -> io::Result<(String, Vec<u8>)> {
    let mut buf = Vec::with_capacity(1024);
    let mut byte = [0u8; 1];
    // read until CRLFCRLF; adequate for a test server
    while !buf.ends_with(b"\r\n\r\n") {
        let n = sock.read(&mut byte).await?;
        if n == 0 {
            break;
        }
        buf.push(byte[0]);
        if buf.len() > 64 * 1024 {
            break;
        }
    }
    let text = String::from_utf8_lossy(&buf).into_owned();
    let path = text
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .unwrap_or("/")
        .to_string();
    // header block = everything after the request line, minus the final CRLF
    let block = match buf.iter().position(|&b| b == b'\n') {
        Some(i) => buf[i + 1..].to_vec(),
        None => Vec::new(),
    };
    Ok((path, block))
}

async fn serve(mut sock: TcpStream) -> io::Result<()> {
    let (path, req_headers) = read_request(&mut sock).await?;
    let seg: Vec<&str> = path.trim_start_matches('/').split('/').collect();

    match seg.as_slice() {
        ["bytes", n] => {
            let n: usize = n.parse().unwrap_or(0);
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\
                 Content-Length: {n}\r\nConnection: close\r\n\r\n"
            );
            sock.write_all(head.as_bytes()).await?;
            let block = vec![b'x'; 64 * 1024];
            let mut left = n;
            while left > 0 {
                let k = left.min(block.len());
                sock.write_all(&block[..k]).await?;
                left -= k;
            }
        }
        ["no-length", n] => {
            let n: usize = n.parse().unwrap_or(0);
            sock.write_all(
                b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
            )
            .await?;
            let block = vec![b'x'; 64 * 1024];
            let mut left = n;
            while left > 0 {
                let k = left.min(block.len());
                sock.write_all(format!("{k:x}\r\n").as_bytes()).await?;
                sock.write_all(&block[..k]).await?;
                sock.write_all(b"\r\n").await?;
                left -= k;
            }
            sock.write_all(b"0\r\n\r\n").await?;
        }
        ["drip", n, ms] => {
            let n: usize = n.parse().unwrap_or(0);
            let ms: u64 = ms.parse().unwrap_or(10);
            sock.write_all(
                b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
            )
            .await?;
            for _ in 0..n {
                sock.write_all(b"1\r\nd\r\n").await?;
                sock.flush().await?;
                tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
            }
            sock.write_all(b"0\r\n\r\n").await?;
        }
        ["delay", ms] => {
            let ms: u64 = ms.parse().unwrap_or(0);
            tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
            sock.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .await?;
        }
        ["status", n] => {
            let n: u16 = n.parse().unwrap_or(200);
            let head = format!(
                "HTTP/1.1 {n} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
            sock.write_all(head.as_bytes()).await?;
        }
        ["dup-headers"] => {
            sock.write_all(
                b"HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\
                  Content-Length: 0\r\nConnection: close\r\n\r\n",
            )
            .await?;
        }
        ["obs-text"] => {
            // a legal obs-text octet (0xE9) in a header value: not UTF-8,
            // and lossy decoding would turn it into U+FFFD
            let mut out: Vec<u8> = b"HTTP/1.1 200 OK\r\nContent-Disposition: inline; name=caf"
                .to_vec();
            out.push(0xE9);
            out.extend_from_slice(b"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            sock.write_all(&out).await?;
        }
        ["echo-headers"] => {
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n",
                req_headers.len()
            );
            sock.write_all(head.as_bytes()).await?;
            sock.write_all(&req_headers).await?;
        }
        _ => {
            sock.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .await?;
        }
    }
    sock.flush().await?;
    Ok(())
}
