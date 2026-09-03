(:rulisp-manifest
 :schema 1
 :abi 1
 :crate "wordbag"
 :crate-version "0.1.0"
 :rulisp-version "0.4.0"
 :target "x86_64-unknown-linux-gnu"
 :prefix "wordbag_rulisp_"
 :on-dump "dump_prep"
 :errors ("ParseError")
 :handles
 ((:handle :rust-name "WordBag" :lisp-name "word-bag" :free "word_bag_free")
  (:handle :rust-name "Grenade" :lisp-name "grenade" :free "grenade_free"))
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
  (:fn :rust-name "sum" :lisp-name "sum" :symbol "sum"
   :params ((:name "data" :type :bytes)) :result :u64 :error nil)
  (:fn :rust-name "rev" :lisp-name "rev" :symbol "rev"
   :params ((:name "data" :type :bytes)) :result :bytes :error nil)
  (:fn :rust-name "find" :lisp-name "find" :symbol "find"
   :params ((:name "data" :type :bytes) (:name "b" :type :u8)) :result (:option :u64) :error nil)
  (:fn :rust-name "greet_opt" :lisp-name "greet-opt" :symbol "greet_opt"
   :params ((:name "name" :type (:option :string))) :result :string :error nil)
  (:fn :rust-name "deltas" :lisp-name "deltas" :symbol "deltas"
   :params ((:name "xs" :type (:vec :i64))) :result (:vec :i64) :error nil)
  (:fn :rust-name "scale" :lisp-name "scale" :symbol "scale"
   :params ((:name "xs" :type (:vec :f64)) (:name "k" :type :f64)) :result (:vec :f64) :error nil)
  (:fn :rust-name "set_notifier" :lisp-name "set-notifier" :symbol "set_notifier"
   :params ((:name "f" :type (:stored-callback :params (:i64) :result :unit)))
   :result :unit :error nil)
  (:fn :rust-name "clear_notifier" :lisp-name "clear-notifier" :symbol "clear_notifier"
   :params () :result :unit :error nil)
  (:fn :rust-name "notify" :lisp-name "notify" :symbol "notify"
   :params ((:name "x" :type :i64)) :result :unit :error "Error")
  (:fn :rust-name "notify_from_thread" :lisp-name "notify-from-thread" :symbol "notify_from_thread"
   :params ((:name "x" :type :i64)) :result :unit :error "Error")
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
  (:fn :rust-name "count_ok" :lisp-name "count-ok" :symbol "count_ok"
   :params ((:name "bag" :type (:handle "WordBag"))
            (:name "f" :type (:callback :params (:string) :result :unit)))
   :result :u64 :error nil)
  (:fn :rust-name "swallow_then_fail" :lisp-name "swallow-then-fail" :symbol "swallow_then_fail"
   :params ((:name "f" :type (:callback :params (:i64) :result :unit)))
   :result :unit :error "Error")
  (:fn :rust-name "WordBag::poison" :lisp-name "word-bag-poison" :symbol "word_bag_poison"
   :params ((:name "self" :type (:handle "WordBag"))) :result :unit :error nil)
  (:fn :rust-name "Grenade::new" :lisp-name "make-grenade" :symbol "grenade_new"
   :params ((:name "armed" :type :bool)) :result (:handle "Grenade") :error nil)
  (:fn :rust-name "test_live_allocations" :lisp-name "test-live-allocations" :symbol "test_live_allocations"
   :params () :result :i64 :error nil)
  (:fn :rust-name "test_live_word_bags" :lisp-name "test-live-word-bags" :symbol "test_live_word_bags"
   :params () :result :i64 :error nil)
  (:fn :rust-name "test_cb_guard_drops" :lisp-name "test-cb-guard-drops" :symbol "test_cb_guard_drops"
   :params () :result :i64 :error nil)
  (:fn :rust-name "dump_prep" :lisp-name "dump-prep" :symbol "dump_prep"
   :params () :result :unit :error "Error")
  (:fn :rust-name "set_dump_prep_fail" :lisp-name "set-dump-prep-fail" :symbol "set_dump_prep_fail"
   :params ((:name "fail" :type :bool)) :result :unit :error nil)
  (:fn :rust-name "test_dump_preps" :lisp-name "test-dump-preps" :symbol "test_dump_preps"
   :params () :result :i64 :error nil)
  (:fn :rust-name "WordBag::from_csv" :lisp-name "make-word-bag-from" :symbol "word_bag_from_csv"
   :params ((:name "csv" :type :string)) :result (:handle "WordBag") :error nil)
  (:fn :rust-name "slow_sum" :lisp-name "slow-sum" :symbol "slow_sum"
   :params ((:name "data" :type :bytes) (:name "millis" :type :u64)) :result :u64 :error nil)
  (:fn :rust-name "slow_dot" :lisp-name "slow-dot" :symbol "slow_dot"
   :params ((:name "xs" :type (:vec :i64)) (:name "millis" :type :u64)) :result :i64 :error nil)))
