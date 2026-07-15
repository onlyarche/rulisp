# rulisp 구현 계획

> 출처: 2026-07-14, 5방향 웹 리서치(도구 호출 274회, 소스 검증) → 3개 독립 설계안 → 2인 판정단 → 합성. 판정단 과정에서 재구성된 7대 리스크는 사후에 리서치 원본과 대조 검증되었고(6/7 일치), 차이 4건은 §11에 기록·반영됨.

## 1. 한 줄 비전 & 스코프 (non-goals 포함)

**비전:** PyO3/rustler의 CL 판 — 사용자는 `#[rulisp::handle]`/`#[rulisp::export]`를 붙인 작은 Rust 글루 크레이트를 쓰고, CL 쪽은 cdylib에 내장된 s-expression 매니페스트를 읽어 CLOS 핸들·condition·finalizer·REPL 리로드가 갖춰진 관용적 패키지를 로드 시점에 생성한다. **하드 요구사항: 생성된 래퍼와 `rulisp:free`만 쓰는 Lisp 코드에서는 GC·스레드·리로드·이미지 덤프의 어떤 인터리빙으로도 UB에 도달할 수 없다** (문서화가 아니라 구조로 봉쇄).

**Non-goals (v0.1 거부 목록):**
- 임의 기존 크레이트 자동 바인딩(bindgen-for-CL) 없음 — 글루 크레이트 작성이 제품이다.
- Lisp 객체의 Rust 측 보유 없음(공리 A1). Rust에 Lisp 참조가 절대 넘어가지 않는다.
- 복합 값 타입 없음: `Vec<T>`/`Option<T>`/구조체 by value 없음. 핸들 또는 `:string`으로 모델링. (범용 `dealloc(ptr,size,align)` ABI 덕에 `(:vec S)`/`:bytes`/`(:option T)`는 v0.2에서 **와이어 브레이크 없이** 추가 가능 — 이것이 dx-first의 dealloc을 접목한 이유.)
- 보관형/크로스스레드/async 콜백 없음. 콜백은 동기·동일 스레드·호출 지속시간 한정 (`!Send` + 라이프타임으로 컴파일 타임 강제). 예약된 `userdata` 슬롯으로 ABI만 열어둠.
- `&mut self` 메서드 없음 — 내부 가변성(Mutex 등)만.
- `dlclose`/진짜 언로드 없음 — 구세대 매핑은 설계상 누수(리로드당 1회, 프로덕션에선 0회).
- Lisp 힙 zero-copy 뷰 없음 — 경계 복사가 계약.
- UTF-8 외 인코딩 없음. Windows v1 없음(Linux/macOS). 이름 매핑 커스터마이즈 없음. 컴파일 타임 바인딩 모드 없음. ASDF가 cargo를 대신 돌리지 않음(§6의 얇은 `use-crate`가 전부).

## 2. 아키텍처 개요

```
      Lisp 이미지 (SBCL 주 타깃)                            libwordbag.so (cdylib)
 ┌─────────────────────────────────────┐              ┌──────────────────────────────────┐
 │ 사용자 REPL / 사용자 시스템            │              │ 사용자 Rust 코드 (safe)            │
 │        │                            │              │  #[rulisp::handle/export]        │
 │        ▼                            │  C ABI v1    │        │ &str, &T, Callback      │
 │ 생성된 래퍼 (패키지 WORDBAG)          │  int32 status│        ▼                         │
 │  · check-type / 수치 코어싱          │  + out-params│ 생성된 extern "C" shim            │
 │  · 핸들 셀 상태기계 + in-flight 계수  │◄────────────►│  · catch_unwind (전 shim)        │
 │  · 콜백 트램폴린 (defcallback)       │ (ptr,len)UTF8│  · UTF-8 검증, Box::into_raw     │
 │        │                            │ void* 핸들   │        │                         │
 │        ▼                            │ (fnptr,udata)│        ▼                         │
 │ rulisp 코어                          │              │ rulisp-runtime (정적 링크)        │
 │  · load-crate / reload-crate        │── dlopen ───►│  · last_error TLS (type+msg)     │
 │  · manifest reader (*read-eval* nil)│  (유니크 사본) │  · dealloc(ptr,size,align)       │
 │  · codegen → COMPILE                │◄─ manifest ──│  · manifest 문자열, module! 등록  │
 │  · generation/session 카운터, 레지스트리│            │  · abi_version                   │
 └─────────────────────────────────────┘              └──────────────────────────────────┘
```

핵심 흐름: `dlopen`(유니크 이름 사본) → `abi_version` 검사 → `manifest` 파싱 → 래퍼/CLOS/condition 생성(COMPILE) → 이후 모든 호출은 status 코드 + out-param 프로토콜.

## 3. 사용자 코드

### 3.1 Rust 글루 크레이트 (`examples/wordbag/`)

```toml
[package]
name = "wordbag"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
rulisp = "0.1"
thiserror = "2"
# panic = "unwind"(기본값) 필수 — rulisp 런타임이 #[cfg(panic="abort")] compile_error!로 강제
```

```rust
use std::sync::Mutex;
use rulisp::prelude::*;   // Error, Callback, 매크로 재수출

// 불투명 핸들. 매크로가 T: Send + Sync + 'static을 강제(위반 시 컴파일 에러).
// shim은 &self만 넘기므로 가변 상태는 내부 Mutex/RwLock/atomics로.
#[rulisp::handle]
pub struct WordBag {
    words: Mutex<Vec<String>>,
}

#[rulisp::export]
impl WordBag {
    #[rulisp(constructor)]              // -> (wordbag:make-word-bag)
    pub fn new() -> WordBag {
        WordBag { words: Mutex::new(Vec::new()) }
    }

    pub fn add(&self, word: &str) -> Result<(), Error> {
        if word.is_empty() {
            return Err(Error::msg("empty word not allowed"));
        }
        self.words.lock().unwrap().push(word.to_owned());
        Ok(())
    }

    pub fn len(&self) -> u64 {
        self.words.lock().unwrap().len() as u64
    }
}

#[rulisp::export]
pub fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

// 타입드 에러: E: std::error::Error. 타입명이 매니페스트 :errors에 실려
// CL 쪽에 WORDBAG:PARSE-ERROR condition 클래스가 생성된다(M3).
#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    #[error("invalid digit found in string: {0:?}")]
    Invalid(String),
}

#[rulisp::export]
pub fn parse_number(s: &str) -> Result<i64, ParseError> {
    s.trim().parse().map_err(|_| ParseError::Invalid(s.to_owned()))
}

// Callback<'a, A, R>은 !Send·!Sync·shim 프레임에 라이프타임 고정 —
// 저장/스레드 이동은 컴파일 에러. f.call(..)? 는 Lisp condition을
// Rust 소멸자를 정상 실행시키며 바깥으로 전파한다.
#[rulisp::export]
pub fn for_each_word(bag: &WordBag, f: Callback<(&str,), ()>) -> Result<u64, Error> {
    let words = bag.words.lock().unwrap();
    for w in words.iter() {
        f.call((w,))?;
    }
    Ok(words.len() as u64)
}

// 명시적 레지스트리 (linkme 대신; minimalist 접목).
// 항목은 경로라서 오타 = 컴파일 에러. handles에 든 타입의 impl 메타는
// 매크로가 붙여둔 연관 const(WordBag::__RULISP_META)로 수집된다.
rulisp::module! {
    name: "wordbag",
    handles: [WordBag],
    fns: [greet, parse_number, for_each_word],
}
```

### 3.2 CL REPL 세션 (M3 완료 시점의 최종 UX)

```lisp
CL-USER> (asdf:load-system :rulisp)

CL-USER> (rulisp:use-crate #p"~/src/wordbag/")     ; cargo build 후 load-crate 호출(얇은 래퍼)
;; cargo build (dev profile) ... ok (0.6s)
#<RULISP:CRATE "wordbag" gen 1 abi 1 :: 4 fns, 1 handle, package WORDBAG>

CL-USER> (wordbag:greet "리스퍼")
"Hello, 리스퍼!"

CL-USER> (wordbag:parse-number "42x")
;; Debugger: WORDBAG:PARSE-ERROR  [RULISP:RUST-ERROR의 서브클래스]
;;   "invalid digit found in string: \"42x\""
;; Restarts: 0: [USE-VALUE] 대체 값을 반환한다.

CL-USER> (defvar *bag* (wordbag:make-word-bag))
#<WORDBAG:WORD-BAG live gen 1 {100A3C2E13}>

CL-USER> (wordbag:word-bag-add *bag* "hello")
; No value
CL-USER> (wordbag:for-each-word *bag*
           (lambda (w) (format t "got ~A~%" w)))
got hello
1

CL-USER> (rulisp:free *bag*)        ; 선택 사항 — GC finalizer도 해제함
T
CL-USER> (rulisp:free *bag*)        ; 멱등
NIL
CL-USER> (wordbag:word-bag-len *bag*)
;; Debugger: RULISP:FREED-HANDLE-ERROR

;; --- Rust 소스 수정 후 ---
CL-USER> (rulisp:reload-crate "wordbag")
#<RULISP:CRATE "wordbag" gen 2 ...>
CL-USER> (wordbag:word-bag-len *old-bag*)          ; 리로드 이전 핸들
;; Debugger: RULISP:STALE-HANDLE-ERROR "handle gen 1, crate gen 2"
CL-USER> (rulisp:free *old-bag*)    ; gen-1의 free 포인터로 해제 — 구 라이브러리는 여전히 매핑됨
T
```

이름 매핑(고정 규칙): 크레이트 `wordbag` → 패키지 `WORDBAG`(`:package` 오버라이드만 허용), `snake_case`→`kebab-case`, 생성자 → `make-<type>`(**인자는 전부 `&key`** — dx-first 접목, 순수 codegen), 메서드 → `<type>-<method>`(핸들이 첫 위치 인자), `Result<(),_>` → `(values)`.

## 4. C ABI 프로토콜 스펙 (abi 1)

모든 심볼은 `<crate>_rulisp_` 프리픽스(하이픈→언더스코어). 각 cdylib이 rulisp-runtime을 **정적으로 각자** 링크하므로(TLS·allocator가 라이브러리별), CL은 well-known 심볼을 반드시 **해당 dlopen 핸들 기준으로** 해석한다 — 이 근거는 BOUNDARY.md에 명기(minimalist 접목).

### 4.1 상태 코드 (모든 shim이 `int32_t` 반환; out-param은 `OK`일 때만 기록됨)

| 코드 | 이름 | 의미 | CL 반응 |
|---|---|---|---|
| 0 | `RULISP_OK` | 성공, out-param 유효 | 값 변환 후 반환 |
| 1 | `RULISP_ERR` | Rust `Err` 반환 | 타입드 condition signal (§6.3) |
| 2 | `RULISP_PANIC` | panic을 shim에서 포획 | `rulisp:rust-panic` signal |
| 3 | `RULISP_INVALID` | 경계 인자 거부(잘못된 UTF-8 등) | `rulisp:invalid-argument` signal |
| 4 | `RULISP_CB_ERR` | Lisp 콜백이 signal → CL 측에 스태시됨 | **원본 condition 재signal** |

예외: `*_free` shim만 `void` 반환. free 내부 panic은 포획해 stderr 로그 후 삼킴(finalizer 문맥엔 에러 채널이 없음).

### 4.2 에러 조회 (dx-first의 type/message 분리 접목 — 와이어는 v1부터 동결)

```c
void wordbag_rulisp_last_error(const uint8_t **type_ptr, uintptr_t *type_len,
                               const uint8_t **msg_ptr,  uintptr_t *msg_len);
```

| 항목 | 규약 |
|---|---|
| 저장 위치 | cdylib 내 thread-local (라이브러리별 독립) |
| 수명 | **차용** — 같은 스레드에서 이 라이브러리로의 다음 호출까지. CL 래퍼는 status 확인 직후 즉시 Lisp 문자열로 복사 |
| type | Rust 에러 타입명 (예: `"ParseError"`); panic 시 `"panic"` |
| msg | `Display` 출력 UTF-8; panic 페이로드가 `&str`/`String`이면 그것, 아니면 `"panic (non-string payload)"` |

### 4.3 panic 규약

| 규칙 | 내용 |
|---|---|
| 포획 | 모든 shim 본문이 `std::panic::catch_unwind(AssertUnwindSafe(..))` → last_error 기록 → status 2 |
| 빌드 가드 | rulisp 런타임에 `#[cfg(panic = "abort")] compile_error!(...)` — panic=abort면 **컴파일 실패** (dx-first 접목; abort 하에선 catch_unwind가 no-op이 되어 첫 panic이 이미지를 죽이는 걸 원천 차단) |
| 이중 방어 | shim은 `extern "C"`(절대 `"C-unwind"` 아님) — 탈출한 panic은 프로세스 abort |

### 4.4 이동 GC (구조적 제거)

Lisp 객체는 경계를 절대 넘지 않는다. 넘는 것은 C 스칼라, 차용 바이트 버퍼, 불투명 Rust 포인터, C 함수 포인터뿐. Rust는 Lisp 참조를 보유할 수 없으므로 gencgc가 옮길 대상 자체가 없다. 콜백 컨텍스트도 정수 키(§4.7).

### 4.5 문자열/버퍼 규약 (양방향 `(ptr, len)` UTF-8 — NUL 종료 불요, 내부 NUL 합법)

| 방향 | 규약 |
|---|---|
| Lisp→Rust | `(const uint8_t*, uintptr_t)`, **호출 지속시간 차용**. CL이 포린 메모리로 복사(`:null-terminated-p nil`). Rust는 `str::from_utf8` 검증(실패 → status 3). 매크로는 사용자에게 `&str`만 주므로 보유는 컴파일 에러 |
| Rust→Lisp | out-param `(uint8_t**, uintptr_t*)`. `String::into_boxed_str`/`Box<[u8]>::into_raw` — len==capacity 보장. **Lisp 소유**, `unwind-protect` 안에서 복사 후 정확히 1회 해제 |
| 해제 | **단일 범용 해제자** (dx-first 접목): `void wordbag_rulisp_dealloc(uint8_t *ptr, uintptr_t size, uintptr_t align);` — 문자열은 align 1. libc `free` 금지; 항상 **할당한 그 라이브러리의** dealloc 호출(프리픽스가 짝 맞춤 보장) |

### 4.6 핸들 규약

| 규칙 | 내용 |
|---|---|
| 표현 | `void*` = `Box::into_raw(Box<T>)`. 생성자는 `void **out`으로 반환 |
| 차용 | 메서드 shim은 `const void*` → `&T` 재구성. `&mut`/by-value 소비 없음 |
| free | 타입별 `void <crate>_rulisp_<type>_free(void*)`. NULL은 no-op. **비-NULL 이중 free는 C 레벨 UB** — 정확히-1회는 CL 측 상태기계(§6.2)가 보장 |
| 타입 안전 | ABI 태그 없음; 타입별 CLOS 클래스 + `check-type`으로 CL에서 강제 |
| 바운드 | `T: Send + Sync + 'static` 컴파일 강제. Send: finalizer가 임의 스레드에서 drop. **Sync: §6.2가 동일 핸들 동시 `&self` 호출을 허용하므로 실질 필수** (방어용이 아니라 하중을 받는 바운드) |

### 4.7 콜백 규약

콜백 파라미터는 C 파라미터 2개로 내려간다: 시그니처별 생성 typedef의 함수 포인터 + 예약 `uint64_t userdata`(v1에선 CL이 0 전달; 보관형 콜백이 생겨도 ABI 브레이크 없도록 예약).

```c
/* Callback<(&str,), ()> 용 */
typedef rulisp_status (*wordbag_rulisp_cbty_0)(
    uint64_t userdata, const uint8_t *a0_ptr, uintptr_t a0_len);
/* 반환: 0 = OK; 1 = Lisp condition 스태시됨 (작업 중단·전파) */
```

| # | 계약 | 강제 수단 |
|---|---|---|
| 1 | 호출 스레드에서만, export 반환 전에만 호출 가능 | `Callback<'a,A,R>`이 `!Send`·`!Sync`·라이프타임 고정 → 저장/이동 = 컴파일 에러 |
| 2 | Lisp condition은 Rust 프레임을 unwind하지 않음 | CL 트램폴린이 `handler-case`로 포획 → thread-local 스태시 → status 1 반환. Rust는 `Err(CallbackError)`로 **정상 unwind**(Drop 실행), `?` 전파 시 터널 플래그 보존 → 외부 shim status 4 → CL이 원본 condition 재signal |
| 3 | Rust가 `CallbackError`를 삼키고 `Ok`/자체 `Err` 반환 시 | CL 래퍼가 **status 4 외 모든 status에서 스태시를 클리어** — 스테일 condition이 이후 호출로 새는 경로 차단 (dx-first 플래그 오분류 결함의 교정판) |
| 4 | `throw`/`return-from`/restart 전이로 콜백 프레임이 Rust를 관통하는 unwind | **문서화된 UB** (dx-first 문구 접목). `handler-case`는 signal된 condition만 잡을 수 있고 임의 비지역 탈출은 막을 수 없다 — "enforced" 과잉 주장(boundary-first 치명 결함)을 정직한 계약으로 교체. 트램폴린의 `unwind-protect`로 발생 시 경고 로그(베스트 에포트 탐지, 방지는 불가). BOUNDARY.md에 명기 |

### 4.8 스레드 규약

| # | 규칙 |
|---|---|
| 1 | 임의 Lisp 스레드가 임의 export 호출 가능; 호출 스레드에서 실행. 전역 락/런타임 없음 |
| 2 | 동일 핸들 동시 메서드 호출 허용(`Sync` 바운드가 담보). free와 진행 중 호출의 경합은 §6.2의 in-flight 계수 + 지연 free로 **도달 불가** |
| 3 | Rust는 내부 스레드를 자유로이 생성 가능하나 거기서 Lisp 콜백 호출 불가(`!Send`로 강제) |
| 4 | finalizer는 임의 스레드에서 실행될 수 있음 — `Send` 바운드 + free shim 무콜백이라 안전 |
| 5 | last_error 조회는 동일 스레드에서 status 직후(생성된 래퍼가 보장) |

### 4.9 라이브러리 수준 진입점 + 생성 shim 시그니처 예

```c
uint32_t       wordbag_rulisp_abi_version(void);           /* == 1, 매니페스트보다 먼저 검사 */
const uint8_t *wordbag_rulisp_manifest(uintptr_t *len);    /* 정적, 영구 차용, 해제 금지 */

/* pub fn greet(name: &str) -> String */
rulisp_status wordbag_rulisp_greet(
    const uint8_t *name_ptr, uintptr_t name_len,
    uint8_t **out_ptr, uintptr_t *out_len);                /* 해제: dealloc(p, *out_len, 1) */

/* WordBag::add(&self, word: &str) -> Result<(), Error> */
rulisp_status wordbag_rulisp_word_bag_add(
    const void *self, const uint8_t *word_ptr, uintptr_t word_len);

/* for_each_word(bag: &WordBag, f: Callback<(&str,), ()>) -> Result<u64, Error> */
rulisp_status wordbag_rulisp_for_each_word(
    const void *self, wordbag_rulisp_cbty_0 f, uint64_t userdata,
    uint64_t *out);

void wordbag_rulisp_word_bag_free(void *self);             /* NULL no-op */
```

로더 시퀀스: dlopen(유니크 사본) → `abi_version` 해석(없으면 "not a rulisp crate") → 버전 불일치 시 `rulisp:abi-mismatch-error` → manifest 읽기 → 바인딩 생성.

## 5. 매니페스트 s-expression 스키마

키워드·문자열·정수만(사용자 심볼 인턴 없음, 리더 매크로 없음). `with-standard-io-syntax` + `*read-eval*` nil + 스크래치 패키지로 읽고, 문법 밖 토큰은 `rulisp:manifest-error`. §3.1 크레이트의 실제 매니페스트:

```lisp
(:rulisp-manifest
 :schema 1                          ; s-expr 형태 버전
 :abi 1                             ; abi_version()과 일치 필수
 :crate "wordbag"
 :crate-version "0.1.0"
 :target "x86_64-unknown-linux-gnu" ; 로드 시 실행 중 Lisp과 대조 (dx-first 접목: 잘못된 아키 .so를 명확한 condition으로)
 :prefix "wordbag_rulisp_"
 :errors ("ParseError")             ; condition 클래스로 생성될 Rust 에러 타입들 (dx-first 접목)
 :handles
 ((:handle :rust-name "WordBag" :lisp-name "word-bag" :free "word_bag_free"))
 :functions
 ((:fn :rust-name "WordBag::new" :lisp-name "make-word-bag" :symbol "word_bag_new"
   :params () :result (:handle "WordBag") :error nil)
  (:fn :rust-name "WordBag::add" :lisp-name "word-bag-add" :symbol "word_bag_add"
   :params ((:name "self" :type (:handle "WordBag")) (:name "word" :type :string))
   :result :unit :error "Error")
  (:fn :rust-name "WordBag::len" :lisp-name "word-bag-len" :symbol "word_bag_len"
   :params ((:name "self" :type (:handle "WordBag"))) :result :u64 :error nil)
  (:fn :rust-name "greet" :lisp-name "greet" :symbol "greet"
   :params ((:name "name" :type :string)) :result :string :error nil)
  (:fn :rust-name "parse_number" :lisp-name "parse-number" :symbol "parse_number"
   :params ((:name "s" :type :string)) :result :i64 :error "ParseError")
  (:fn :rust-name "for_each_word" :lisp-name "for-each-word" :symbol "for_each_word"
   :params ((:name "bag" :type (:handle "WordBag"))
            (:name "f" :type (:callback :params (:string) :result :unit)))
   :result :u64 :error "Error")))
```

- **타입 어휘 (v1, 폐집합):** `:unit :bool :i8 :i16 :i32 :i64 :u8 :u16 :u32 :u64 :f32 :f64 :string (:handle "Name") (:callback :params (...) :result ...)`. 어휘 밖 = 매크로 `compile_error!`(Rust) / `manifest-error`(CL, 함수명 지목, 반쪽 생성 금지). `(:vec S)`/`:bytes`/`(:option T)`는 v0.2 추가 후보 — dealloc ABI와 unknown-key 무시 규칙 덕에 순수 가산적.
- `:error` 필드가 boundary-first의 `:fallible`을 대체(condition 클래스명 운반; `nil` = 무오류. 어떤 호출이든 PANIC은 가능하므로 status 검사는 항상 수행).
- **버저닝:** `:abi`는 §4 와이어 브레이크 시에만 범프, 정확 일치 요구. `:schema`는 기존 키 의미 변경 시에만 범프, `schema <= 지원치` 수락. **unknown 키는 무시**(가산 진화 무료).
- **임베딩/조회:** M1–M2에서는 손으로 쓴 `wordbag.manifest.sexp`를 `include_str!`로 서빙(minimalist의 계약 동결 접목) — **조회 채널은 이후 절대 불변**이라 CL 로더는 M2에 완성·동결된다. M3의 `module!`은 같은 문자열을 `OnceLock<String>`에 조립할 뿐.

## 6. CL 측 설계

### 6.1 바인딩 생성 시점: **로드 타임 함수** (확정)

`rulisp:load-crate`는 평범한 함수다: dlopen → ABI 검사 → 매니페스트 파싱 → defun/defclass/define-condition 폼을 데이터로 구성 → `COMPILE` → 대상 패키지에 인턴·export. 심볼 주소는 생성 시점에 해당 라이브러리 핸들로 1회 해석해 `cffi:foreign-funcall-pointer`로 호출.

근거 3축: **(REPL)** 폼 하나로 컴파일된 API가 즉시 존재, 재실행 저렴. **(compile-file)** 컴파일 타임 매크로는 매크로 확장 시점에 `.so`를 요구하고 fasl에 정의를 굽는다 — 어제의 `.so`로 컴파일된 fasl이 오늘 로드된 `.so`와 조용히 어긋나는 "거짓말하는 바인딩"이 바로 매니페스트 아키텍처가 없애려는 실패 모드. 로드 타임 생성이면 바인딩은 방금 dlopen한 그 라이브러리에서 정의상 유도된다. **(이미지 덤프)** 복원 시 어차피 포린 포인터가 죽으므로 재생성이 필수 — 복원을 같은 코드 경로의 재실행으로 만든다(§6.5). dx-first의 "복원 시 재생성 불요" 주장(치명 결함: 스테일 SAP)을 명시적으로 기각.

### 6.2 핸들 셀 상태기계 — **in-flight 계수 + 지연 free** (boundary-first 치명 결함 교정)

핸들 인스턴스마다 **셀**: `{ptr, state ∈ {LIVE, FREE-PENDING, FREED}, generation, session, in-flight: 정수, free-fn-pointer(생성 세대의 것을 캡처), lock}`. CLOS 래퍼가 셀을 보유; `trivial-garbage` finalizer는 **래퍼가 아닌 셀**을 클로저로 캡처(래퍼를 잡으면 영원히 garbage가 안 됨).

**락 규율 (심판 지적 데드락의 교정 핵심): 락은 상태 전이만 보호하고, 포린 호출 동안엔 절대 잡지 않는다.**

```
메서드 호출:  lock → [LIVE ∧ gen=래퍼 출생 세대 ∧ session=현재] 검사 → in-flight++ → unlock
              (signal은 반드시 unlock 이후 — 핸들러는 unwind 전에 signal 프레임에서 실행되므로
               락을 쥔 채 signal하면 핸들러 코드가 같은 락에 데드락할 수 있다)
              → 포린 호출 (락 없음 — 콜백 재진입·동일 핸들 중첩 호출 자유)
              → lock → in-flight-- → state=FREE-PENDING ∧ in-flight=0이면 unlock 후 free-fn 호출, state=FREED
   검사 실패:  FREED/FREE-PENDING → FREED-HANDLE-ERROR
              gen≠래퍼 출생 세대   → STALE-HANDLE-ERROR
              session≠현재        → STALE-HANDLE-ERROR (포린 호출 절대 안 함)

   ⚠ 비교 대상은 크레이트의 "현재" 세대가 아니라 **호출하는 래퍼의 출생 세대**다. 래퍼 클로저는
   자기 fn-ptr가 해석된 세대의 것이므로, 캡처된 구세대 래퍼가 신세대 핸들을 받으면 현재-세대
   비교로는 게이트가 통과되어 구세대 셔임이 신세대 할당을 역참조한다(M1 리뷰에서 재현된 UB).
   같은 이유로 래퍼는 last-error/dealloc/free 포인터 전부를 출생 세대의 불변 컨텍스트(gen-ctx)로
   캡처하고, 진입 시 session 게이트로 죽은 이미지의 클로저를 거부한다.

free / finalizer:  lock → FREED → NIL 반환 (멱등)
                        → in-flight=0 → free-fn 호출, state=FREED, T 반환
                        → in-flight>0 → state=FREE-PENDING, T 반환
                          (실제 drop은 마지막 진행 중 호출이 빠져나올 때)
스테일 gen free:   캡처된 gen-N free 포인터 호출 — 구 라이브러리는 여전히 매핑(A5),
                   자기 allocator가 자기 Box를 해제. 안전하고 누수 없음.
죽은 session free: 포린 호출 없이 state=FREED (포인터는 이전 프로세스 이미지 소속).
```

이 하나의 메커니즘이 (a) free-vs-진행중-호출 UAF 경합(도달 불가), (b) 재진입 콜백 데드락(락을 호출 중 안 잡음), (c) 콜백이 자기 수신자를 free하는 경우(지연 free), (d) 이중 free(FREED에서 멱등), (e) 리로드·복원 후 오폭(gen/session 게이트)을 전부 닫는다. 동일 핸들 동시 호출은 허용되며 건전성은 `T: Sync` 바운드가 담보(§4.6).

### 6.3 condition 체계와 restart

```
rulisp:rulisp-error
 ├─ rulisp:rust-error            (슬롯: message, rust-type, function-name)
 │    └─ <crate>:<error>-…       ; 매니페스트 :errors에서 생성 (예: wordbag:parse-error) — M3
 ├─ rulisp:rust-panic            (슬롯: message)
 ├─ rulisp:invalid-argument
 ├─ rulisp:invalid-handle-error
 │    ├─ rulisp:freed-handle-error
 │    └─ rulisp:stale-handle-error   (슬롯: handle-generation, crate-generation)
 ├─ rulisp:crate-not-loaded-error
 ├─ rulisp:build-error           (슬롯: cargo stderr)
 ├─ rulisp:manifest-error
 └─ rulisp:abi-mismatch-error
```

**판정 조정(타입드 condition):** risk 심판은 v1 접목, simplicity 심판은 v0.2 이연 — **와이어(§4.2 type 필드 + 매니페스트 `:errors` 키)는 v1에 동결하고 condition 클래스 codegen만 M3에 넣는다.** 동결 후 못 바꾸는 건 와이어뿐이고 codegen은 언제든 가산적이기 때문. M1–M2에서는 `rust-error`의 `rust-type` 슬롯으로 판별 가능.

Restart: 가류 래퍼에 `use-value`(dx-first 접목, 한 코드 경로 몇 줄), `use-crate`/`reload-crate`에 `retry-build`. v1 restart는 이 둘로 끝.

**콜백 스태시 규율:** 트램폴린(`cffi:defcallback`, 시그니처 형태별 1개; 라이브 클로저는 포린 호출 주위에 동적 바인딩되는 thread-local special로 전달 — 계약 1 덕에 건전, 동적 바인딩이라 중첩 자동 처리)이 `handler-case`로 condition을 스태시하고 1 반환. 래퍼는 status 4면 스태시 재signal, **그 외 모든 status에서 스태시 클리어**.

### 6.4 finalizer / print-object

- finalizer는 셀 캡처, §6.2 경로로만 해제. 임의 스레드 실행 → `Send` 바운드가 커버.
- `print-object`: `#<WORDBAG:WORD-BAG live gen 1 {…}>`; freed/stale이면 상태 표시(dx-first 접목). Rust `Display` shim 연동은 v0.2 후보(unknown-key 규칙 덕에 가산적) — v1은 상태 표시까지만. 이유: FFI 왕복 프린팅은 폴리시일 뿐 리스크 커버가 아니므로 최소 범위 유지.

### 6.5 리로드와 이미지 덤프/복원

- **리로드:** `reload-crate` = cargo 산출물을 캐시 디렉터리의 **유니크 이름**(`<crate>-<gen+1>.so`)으로 복사 후 dlopen(경로 캐싱 무력화 — macOS dyld의 "리로드가 거짓말" 문제 봉쇄) → ABI/매니페스트 검증 → 같은 패키지에 래퍼 재생성(사라진 export는 `fmakunbound`) → generation++. 구세대 핸들은 호출 거부(STALE)하되 캡처된 gen-N free 포인터로 해제는 허용. 구 매핑은 영구 유지(A5, `dlclose` 금지).
- **덤프:** `uiop:register-image-dump-hook`이 CFFI의 Lisp 측 라이브러리 레코드 정리.
- **복원:** `uiop:register-image-restore-hook`이 **먼저 전역 `*session*`++** (훅의 나머지가 실패해도 모든 덤프 이전 핸들이 즉시 무효) → 레지스트리의 각 크레이트에 대해 기록된 경로로 `load-crate` 재실행(심볼 주소·래퍼 전면 재생성 — 스테일 SAP 불가). `.so` 부재 시 경고로 강등, 해당 래퍼 호출은 `crate-not-loaded-error`.

### 6.6 `use-crate` (얇은 cargo 오케스트레이션 — 양 심판 공통 접목, simplicity 심판 규모로)

`load-crate`가 프리미티브로 남고, `use-crate`는 ~40줄 래퍼: `uiop:run-program`으로 `cargo build`(기본 dev, `:profile :release` 옵션) → 실패 시 stderr를 실은 `build-error` + `retry-build` restart → `Cargo.toml`에서 크레이트명 스크레이프 → 산출물을 세대 번호 캐시 경로로 복사 → `load-crate`. mtime 휴리스틱 없음 — cargo의 자체 no-op 검사에 위임.

### 6.7 공개 API (v1 전체)

```
rulisp:load-crate path &key package crate      → crate 객체 (프리미티브)
rulisp:use-crate crate-dir &key profile package → cargo build + load-crate
rulisp:reload-crate crate-or-name &key path    → crate 객체 (gen+1)
rulisp:free handle                             → 지금 해제(또는 지연 예약)면 T, 이미 FREED면 NIL
rulisp:crate  rulisp:handle                    ; CLOS 클래스 / 추상 상위클래스
+ §6.3의 condition 트리
```

## 7. 리포 레이아웃

```
rulisp/
├── Cargo.toml                  # workspace = ["crates/*", "examples/wordbag", "tests/m1-handwritten"]
├── Makefile                    # test-m1 ... test-m4: 단일 명령 게이트
├── crates/
│   ├── rulisp/                 # 사용자 대면: prelude, Error, Callback, module!, 매크로 재수출
│   ├── rulisp-macros/          # proc-macro: #[handle] #[export] #[rulisp(constructor)] (M3까지 빈 껍데기)
│   └── rulisp-runtime/         # catch_unwind 헬퍼, last_error TLS, dealloc, manifest 조립,
│                               #   #[cfg(panic="abort")] compile_error!
├── lisp/
│   ├── rulisp.asd              # 시스템: :rulisp, :rulisp/test
│   └── src/
│       ├── package.lisp
│       ├── conditions.lisp
│       ├── ffi.lisp            # per-library 심볼 해석, status 디코드, last-error 복사
│       ├── manifest.lisp       # 하드닝된 reader + 스키마 검증
│       ├── handle.lisp         # 셀, 상태기계+in-flight, finalizer, gen/session
│       ├── codegen.lisp        # 매니페스트 → 폼 → COMPILE → 패키지 인턴
│       ├── crate.lisp          # load-crate/reload-crate, 레지스트리, dump/restore 훅
│       └── build.lisp          # use-crate: cargo 호출, 캐시, Cargo.toml 스크레이프
├── examples/wordbag/           # §3 크레이트 + demo.lisp
│   └── wordbag.manifest.sexp   # M1–M2 수기 매니페스트 (M3에서 삭제됨)
├── tests/
│   ├── m1-handwritten/         # M1 수기 shim 크레이트 — 영구 보존, ABI 오라클
│   ├── golden/                 # 매니페스트 골든 스냅샷 (M3 바이트 동일성 게이트)
│   └── suite/                  # fiveam 스위트 (m1/reload/threads/image/callbacks)
└── BOUNDARY.md                 # §4 계약 전문 + 문서화된 UB 조항 + per-library 심볼 근거
```

CL 의존성: `cffi`, `babel`, `trivial-garbage`, `bordeaux-threads`, `uiop` (+테스트 `fiveam`). Rust 의존성: `syn`/`quote`/`proc-macro2`만(linkme 제거 — 명시적 레지스트리 채택 이유: 의존성 하나 감소 + 오타가 컴파일 에러).

## 8. 마일스톤 M1–M4

**M1 — 경계 수직 슬라이스 (수기 shim, proc-macro 0줄, 수기 매니페스트 include_str! 서빙, CL 로더는 진짜 프로덕션 코드).** 8항목(스칼라 스모크 + 7대 리스크), 각각 fiveam 테스트 1개 이상:
0. **스칼라/성능:** `add(i64,i64)->i64` — cargo 빌드 → dlopen → codegen 최소 경로 스모크 + 마이크로벤치(네이티브 SBCL 함수 대비; 리서치 기준선 ~10–100ns/call 확인).
1. **panic:** 고의 panic export → `rust-panic` + 정확한 페이로드 메시지, 이미지 생존. panic=abort 크레이트가 컴파일 실패하는 것도 확인.
2. **가류 fn:** `parse-number "42x"` → `rust-error`, `rust-type` = `"ParseError"`, 메시지 정확 일치.
3. **문자열:** `""`/ASCII/`"한글 🦀"` 왕복; 테스트용 할당 카운터 export가 호출 후 기준선 복귀(dealloc 짝 맞춤 증명).
4. **핸들:** make/use/`free` 멱등/UAF signal; 미참조 핸들 1000개 + `(sb-ext:gc :full t)` → Rust live-count 0; **신규 — free-vs-진행중-호출:** 스레드 A가 느린 메서드 안에 있는 동안 스레드 B가 `free` → B는 T, A는 정상 완료, drop은 A 퇴장 후(Rust drop-플래그로 증명).
5. **콜백:** N회 동기 호출; 클로저 내 signal이 바깥에서 **동일 객체로**(eq) 재signal + Rust drop-플래그로 소멸자 실행 증명; **신규 — 재진입:** 콜백 본문이 같은 핸들의 메서드 호출(데드락 없음), 콜백이 자기 수신자 `free`(지연 free, 외부 호출 정상 완료).
6. **리로드:** 문자열 상수 수정·재빌드·`reload-crate` → 새 동작; 구 핸들 메서드 → `stale-handle-error`; 구 핸들 `free` → T (gen-1 free 포인터 경유).
7. **덤프/복원:** 스크립트가 라이브 크레이트+핸들로 실행 파일 덤프; 재시작 시 크레이트 자동 재로드, 덤프 이전 핸들 signal, 새 핸들 정상.

**인수 기준:** `make test-m1` = `cargo build` + `sbcl --script` 가 SBCL 2.6 / Linux x86-64에서 exit 0.
(판정 조정: simplicity 심판의 "콜백을 M1에서 빼라"는 기각 — 과제가 7항목 슬라이스를 M1로 못박았고, 재진입 콜백이 §6.2 락 규율의 정당성을 검증하는 유일한 테스트라 미룰 수 없다.)

**M2 — CL 측 완성·계약 동결 (minimalist 규율).** 수기 매니페스트 채널 확정, 매니페스트 검증 픽스처(오염/버전 불일치 → 명명된 condition, 반쪽 생성 절대 금지), `:target` 검사, `use-value` restart, `use-crate`.
**인수 기준:** `make test-m2` — M1 스위트 + 픽스처 스위트 그린; **이 시점에 `lisp/`는 기능 동결 선언**(M3는 CL 코드를 건드리지 않아야 함); `wordbag.manifest.sexp` 사본이 `tests/golden/`에 스냅샷됨.

**M3 — proc-macro + DX.** `#[rulisp::handle]`/`#[rulisp::export]`/`module!{}`가 M1 수기물을 재생산; `:errors` → 타입드 condition 클래스 codegen; 생성자 `&key` 인자.
**인수 기준:** `make test-m3` = (a) 매크로 생성 매니페스트가 골든 스냅샷과 **바이트 동일**; (b) `examples/wordbag`에서 수기 shim과 `.sexp` 파일 **삭제** 후 **무변경** M1/M2 CL 스위트 통과(`tests/m1-handwritten/`은 ABI 오라클로 영구 보존); (c) trybuild 컴파일 실패 테스트: 비-`Send+Sync` 핸들, `&mut self`, 구조체에 저장된 `Callback`, 어휘 밖 타입, `module!` 레지스트리 오타 — 각각 실행 가능한 메시지와 함께 실패; (d) `wordbag:parse-error`가 signal되는 §3.2 트랜스크립트 테스트(주소/시간 제외 일치).

**M4 — 하드닝 + 0.1 릴리스.** (a) 경합 테스트: 8스레드 × 10k회 공유 핸들에 메서드/`free`/gc 혼합 — 크래시 0, 올바른 condition만; (b) 중첩 콜백(콜백 본문이 또 다른 콜백 수용 export 호출); (c) 무작위 op 시퀀스 1만 회(핸들/리로드/덤프 혼합)에도 이미지 생존; (d) M1 항목 6–7을 매크로 파이프라인에서 재검증; (e) BOUNDARY.md 완성(§4 계약 + UB 조항 + 시그널 규칙 전문); (f) 배포 가이드 문서화: Shirakumo식 플랫폼별 blob 패턴 + Deploy(실행파일) 연동 — 코드 구현은 v0.2.
**인수 기준:** CI 매트릭스 그린 — Linux x86-64 + macOS arm64 × SBCL(필수) + CCL(필수), ECL 베스트 에포트·강등 문서화; `rulisp`/`rulisp-macros` crates.io 게시; ASDF 시스템 Ultralisp/Quicklisp 제출; 태그 `0.1.0`.
(판정 조정: dx-first의 3구현×2OS 필수 매트릭스는 일정 치명 지적을 수용해 SBCL+CCL 필수 / ECL 베스트 에포트로 축소.)

## 9. 리스크 → 설계 대응표

| # | 리스크 | 봉쇄 지점 | 검증 |
|---|---|---|---|
| 1 | Rust panic이 FFI 경계를 넘어 unwind | §4.3: 전 shim `catch_unwind` + `#[cfg(panic="abort")] compile_error!` + `extern "C"` abort 이중방어 | M1-1 |
| 2 | SBCL 이동 GC vs Rust가 쥔 포인터 | §4.4 공리 A1: Lisp 객체 불횡단 — 경계 복사, 콜백 ctx는 정수, 완화가 아닌 **제거** | 구조적(테스트 불요) + M1-3 복사 검증 |
| 3 | 핸들 이중 free / UAF (free-vs-진행중-호출 포함) | §6.2 셀 상태기계 + **in-flight 계수 + 지연 free**; free는 단일 경로; C 레벨 NULL no-op | M1-4, M4-a |
| 4 | 문자열 소유권/인코딩 (내부 NUL, allocator 짝) | §4.5: 양방향 `(ptr,len)` UTF-8, len==capacity, 라이브러리별 `dealloc(ptr,size,align)`, `unwind-protect` 해제 | M1-3 |
| 5 | 콜백/스레드/시그널 (조건 unwind, 크로스스레드, 재진입) | §4.7: `!Send`+라이프타임 컴파일 강제, 트램폴린 `handler-case`+스태시+클리어 규율, `throw` 등은 **문서화된 UB**; §6.2가 재진입 데드락 제거. 시그널: 순수 Rust cdylib은 핸들러 미설치(소스 검증) — 글루 크레이트 의존성의 `sigaction` 감사(wasmtime/JIT/crash-handler 계열 금지), SIGINT/SIGTERM은 Lisp 소유 + Rust엔 명시적 shutdown fn — BOUNDARY.md에 규칙화 | M1-5, M4-b |
| 6 | `save-lisp-and-die` 후 스테일 포인터/SAP | §6.5: **session++ 최우선** → `load-crate` 전면 재실행(심볼 재해석); 죽은 session free는 포린 호출 생략 | M1-7, M4-d |
| 7 | 라이브 리로드 (dlopen 캐싱, 구세대 핸들) | §6.5: 유니크 이름 사본 dlopen(macOS dyld 캐싱 봉쇄), `dlclose` 금지, generation 게이트, gen-N free 포인터 캡처로 무누수 해제 | M1-6, M4-d |
| 8 | 배포 (Quicklisp 빌드 호스트에 cargo 없음, macOS Gatekeeper의 다운로드 dylib 격리, Windows DLL 잠금) | v0.1 사용자는 글루 크레이트 개발자 = cargo 보유 전제라 비치명. 라이브러리 배포는 Shirakumo식 플랫폼별 blob 커밋(`lib<name>-<os>-<arch>.<ext>`) + Ultralisp/ocicl, 실행파일은 Deploy — M4-(f)에서 가이드 문서화, 구현은 v0.2 | M4-f |

교차 불변식(모든 마일스톤이 재검증): panic 불횡단 / Lisp unwind가 Rust 프레임 불관통(조건 한정, 그 외 UB 문서화) / Lisp 힙 포인터 Rust 불보유 / 모든 Rust 할당은 같은 라이브러리의 dealloc·free로 / 모든 핸들은 최대 1회, 출생 세대로만 해제 / 전 심볼 크레이트 프리픽스.

## 10. 판정단 요약

두 심판(risk-correctness, simplicity-dx) 모두 **boundary-first 승리** — 7대 리스크를 문서가 아닌 구조로 닫은 유일한 안. 접목: dx-first에서 범용 `dealloc(ptr,size,align)`, last-error type/message 분리 + `:errors` 기반 타입드 condition(와이어 v1/codegen M3로 절충), panic=unwind 컴파일 가드, 얇은 `use-crate`+`build-error`/`retry-build`, `use-value` restart, `:target` 검사, 생성자 `&key`, 비지역 탈출의 정직한 documented-UB 문구; minimalist에서 매니페스트 계약 동결(M1–M2 수기 `.sexp` → M3 삭제+바이트 동일 게이트)과 linkme 대체 명시적 `module!` 레지스트리. 수정한 치명 결함: 재진입 콜백 데드락 → 락은 상태 전이만 보호하는 **in-flight 계수 + 지연 free**로 재설계(UAF 경합도 동시 봉쇄), 계약 3의 "enforced" 과잉 주장 → UB 조항으로 교체, panic=abort 무가드 → `compile_error!` 추가. 판정 불일치 2건은 §6.3(타입드 condition 시점)과 §8 M1(콜백 포함 유지)에서 한 줄 근거와 함께 조정했다.

## 11. 리서치 원본 대조 검증 기록

설계 단계에서 리서치 합성본 전달이 누락되어(오케스트레이션 인자 버그) 설계안들이 7대 리스크를 자체 재구성했다. 사후 대조 결과 6/7이 리서치와 일치했고, 다음 4건을 조정 반영했다:

1. **배포 리스크 복원** — 재구성에서 유일하게 누락. §9 표 8행 + M4-(f)로 반영. 리서치 검증 사실: Quicklisp 정책상 cargo 요구 시스템은 사실상 등재 불가, macOS Gatekeeper는 다운로드된 dylib을 격리(다운로드-온-로드 방식 불가), `CFFI_FOREIGN_LIBRARY_PATH` 환경변수는 존재하지 않음.
2. **M1 항목 0 추가** — 리서치 M1의 스칼라 함수 + 마이크로벤치 항목이 빠져 있어 복원.
3. **시그널 규칙 명시** — 리서치 리스크 #1(스레드+시그널)의 시그널 부분을 §9 5행과 BOUNDARY.md 요구사항에 반영. 소스 검증 사실: 순수 Rust cdylib(tokio 포함)은 시그널 핸들러를 설치하지 않고, SBCL은 외부 스레드 콜백 진입을 지원한다.
4. **크로스스레드 콜백의 의도적 이연** — 리서치 M1은 "Rust 스레드에서 Lisp 콜백 호출"(foreign-thread adoption) 검증을 포함했으나, 본 설계는 건전성 우선으로 v1 콜백을 동기·동일 스레드로 제한했다(판정단 승인). SBCL의 foreign-thread adoption은 소스 검증된 사실이므로 v0.2 async/보관형 콜백 설계 시 활용 가능하며, §4.7의 예약된 `userdata` 슬롯이 ABI 브레이크 없는 확장을 보장한다.

5. **M1 구현 후 적대적 리뷰 반영 (2026-07-14)** — 3렌즈(동시성/FFI 소유권/설계 준수) 리뷰에서 18건 발견, 검증 단계에서 18건 전원 확정(기각 0). 핵심 교정: (a) §6.2 게이트 의사코드의 "gen=현재"가 오류였음 — 캡처된 구세대 래퍼가 신세대 핸들을 통과시켜 세대 교차 UB에 도달(0xDEADBEEF 마커로 재현됨). 게이트는 **래퍼 출생 세대** 비교로 수정되고, 래퍼는 세대별 불변 컨텍스트(gen-ctx: fn-ptr/last-error/dealloc/free 테이블)를 캡처하며 진입 시 session 게이트를 갖는다. (b) 락을 쥔 채 signal 금지(§6.2에 명문화). (c) 트램폴린은 serious-condition 포획 + unwind-protect 비지역 탈출 경고(§4.7-4 이행). (d) load/reload/restore는 레지스트리 락으로 직렬화. (e) 캐시 사본은 세대 커밋 시 청소(매핑은 유지, 파일만 unlink). (f) `load-crate`는 스펙대로 `&key package crate`, 정식 크레이트명은 매니페스트 `:crate`를 채택(하이픈 크레이트명 문제 해소). (g) 핸들 print-object는 세대 스테일도 표시, 공유 패키지의 핸들 클래스 소유권 충돌은 manifest-error. 전 항목 회귀 테스트 추가, 59/59 통과.

6. **M3 구현 조정 (2026-07-14)** — (a) 워크스페이스는 같은 이름의 패키지 둘을 허용하지 않으므로 오라클(tests/m1-handwritten)을 워크스페이스에서 분리(자체 `[workspace]`)하고 examples/wordbag을 멤버로 편입 — 둘 다 패키지명 "wordbag"을 유지해 golden 바이트 동일성이 성립한다. (b) golden의 줄바꿈은 폭 기반이었음이 판명 — 렌더러는 3단계 레이아웃(≤100자 한 줄 → :result 줄 분리 → param 별 줄)으로 재현한다. (c) `module!`의 `fns:` 목록은 메서드 경로(`WordBag::new`)까지 명시하는 전체 순서 목록이다 — 매니페스트 함수 순서를 사용자가 제어하고, 오타는 미해결 const 컴파일 에러가 된다. (d) 생성자 `&key` 인자는 v0.2로 이연 — 매니페스트 확장(unknown-key 무시로 무파괴)과 CL codegen 변경이 함께 필요하며, v1 게이트는 0-인자 생성자로 충족된다. (e) "lisp/ 기능 동결"은 와이어/로더 의미론의 동결로 해석한다 — §6.3 판정 조정이 M3에 예정해 둔 타입드 condition codegen(:errors → rust-error 서브클래스)은 가산적 CL 변경으로 M3에서 구현되었다. (f) `Callback`은 선언 튜플과 호출 튜플의 라이프타임을 분리하는 `CbArgsFor<Decl>` 트레이트를 갖는다 — 선언 라이프타임에 호출 인자를 묶으면 지역 데이터를 콜백에 넘길 수 없다.

7. **M4 완료 기록 (2026-07-15)** — (a) 8스레드×10k 경합, (b) 중첩 콜백(2단 Rust 프레임 관통 condition eq-동일성), (c) 무작위 10k 시퀀스+리로드 — 모두 그린(101/101). (d)는 run-m3/m4가 무변경 M1 스위트(리로드·덤프 포함)를 매크로 파이프라인으로 실행하는 것으로 충족. **CCL 1.13/Linux 검증 완료(99/99)** — 발견된 이식성 이슈 2건: 보수적 스택 스캔 호스트에서 GC finalize 잔여 허용(#-sbcl slack 2), prepare 단계 전방참조 경고는 muffle-warning restart 존재 확인 후 muffle. 이미지 덤프 테스트는 비-SBCL에서 vacuous pass(구현별 덤프는 v0.2). BOUNDARY.md(영문 규범 계약)·README·LICENSE(MIT)·docs/distribution.md(배포 가이드)·.github/workflows/ci.yml(SBCL/CCL Linux 필수 + macOS 필수 + ECL best-effort) 작성. crates 3종 `cargo package` 검증 통과(게시 순서: runtime → macros → rulisp). 태그 v0.1.0. **원격 작업(사용자 계정 필요, 미실행): GitHub 리포 생성/push, crates.io 게시, Ultralisp 등록, 원격 CI 첫 실행.**

원본 자료: 리서치 5종 + 종합(`wbqzsl9yo.output`), 설계 3안 + 판정 2건(`w1bva0j8v.output`), M1 리뷰 18건(`weic0xw2b.output`) — 세션 산출물 디렉터리에 보존.