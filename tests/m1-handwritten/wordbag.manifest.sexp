(:rulisp-manifest
 :schema 1
 :abi 1
 :crate "wordbag"
 :crate-version "0.1.0"
 :target "x86_64-unknown-linux-gnu"
 :prefix "wordbag_rulisp_"
 :errors ("ParseError")
 :handles
 ((:handle :rust-name "WordBag" :lisp-name "word-bag" :free "word_bag_free"))
 :functions
 ((:fn :rust-name "add" :lisp-name "add" :symbol "add"
   :params ((:name "a" :type :i64) (:name "b" :type :i64)) :result :i64 :error nil)
  (:fn :rust-name "always_panic" :lisp-name "always-panic" :symbol "always_panic"
   :params () :result :unit :error nil)
  (:fn :rust-name "parse_number" :lisp-name "parse-number" :symbol "parse_number"
   :params ((:name "s" :type :string)) :result :i64 :error "ParseError")
  (:fn :rust-name "greet" :lisp-name "greet" :symbol "greet"
   :params ((:name "name" :type :string)) :result :string :error nil)
  (:fn :rust-name "echo" :lisp-name "echo" :symbol "echo"
   :params ((:name "s" :type :string)) :result :string :error nil)
  (:fn :rust-name "WordBag::new" :lisp-name "make-word-bag" :symbol "word_bag_new"
   :params () :result (:handle "WordBag") :error nil)
  (:fn :rust-name "WordBag::add" :lisp-name "word-bag-add" :symbol "word_bag_add"
   :params ((:name "self" :type (:handle "WordBag")) (:name "word" :type :string))
   :result :unit :error "Error")
  (:fn :rust-name "WordBag::len" :lisp-name "word-bag-len" :symbol "word_bag_len"
   :params ((:name "self" :type (:handle "WordBag"))) :result :u64 :error nil)
  (:fn :rust-name "WordBag::slow_len" :lisp-name "word-bag-slow-len" :symbol "word_bag_slow_len"
   :params ((:name "self" :type (:handle "WordBag")) (:name "millis" :type :u64))
   :result :u64 :error nil)
  (:fn :rust-name "for_each_word" :lisp-name "for-each-word" :symbol "for_each_word"
   :params ((:name "bag" :type (:handle "WordBag"))
            (:name "f" :type (:callback :params (:string) :result :unit)))
   :result :u64 :error "Error")
  (:fn :rust-name "test_live_allocations" :lisp-name "test-live-allocations" :symbol "test_live_allocations"
   :params () :result :i64 :error nil)
  (:fn :rust-name "test_live_word_bags" :lisp-name "test-live-word-bags" :symbol "test_live_word_bags"
   :params () :result :i64 :error nil)
  (:fn :rust-name "test_cb_guard_drops" :lisp-name "test-cb-guard-drops" :symbol "test_cb_guard_drops"
   :params () :result :i64 :error nil)))
