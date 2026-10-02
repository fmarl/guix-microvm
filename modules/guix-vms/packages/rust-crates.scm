(define-module (guix-vms packages rust-crates)
  #:use-module (guix build-system cargo)
  #:export (lookup-cargo-inputs))

;; Generated with `guix import crate --lockfile=Cargo.lock virtiofsd' from
;; the virtiofsd crate's Cargo.lock.

(define rust-aho-corasick-0.7.18
  (crate-source "aho-corasick" "0.7.18"
                "0vv50b3nvkhyy7x7ip19qnsq11bqlnffkmj2yx2xlyk5wzawydqy"))

(define rust-anstream-0.3.2
  (crate-source "anstream" "0.3.2"
                "0qzinx9c8zfq3xqpxzmlv6nrm3ymccr4n8gffkdmj31p50v4za0c"))

(define rust-anstyle-1.0.1
  (crate-source "anstyle" "1.0.1"
                "1kff80219d5rvvi407wky2zdlb0naxvbbg005s274pidbxfdlc1s"))

(define rust-anstyle-parse-0.2.1
  (crate-source "anstyle-parse" "0.2.1"
                "0cy38fbdlnmwyy6q8dn8dcfrpycwnpjkljsjqn3kmc40b7zp924k"))

(define rust-anstyle-query-1.0.0
  (crate-source "anstyle-query" "1.0.0"
                "0js9bgpqz21g0p2nm350cba1d0zfyixsma9lhyycic5sw55iv8aw"))

(define rust-anstyle-wincon-1.0.1
  (crate-source "anstyle-wincon" "1.0.1"
                "12714vwjf4c1wm3qf49m5vmd93qvq2nav6zpjc0bxbh3ayjby2hq"))

(define rust-arc-swap-1.5.0
  (crate-source "arc-swap" "1.5.0"
                "07sb99f18spqmjx7f4cmqx7hc8ayspcmw9shl4zjvf300ki8rmy5"))

(define rust-atomic-polyfill-0.1.11
  (crate-source "atomic-polyfill" "0.1.11"
                "0a4vd4zq75xmwbi33flf35qmm2nf99kx3hx2m21lslqnyfrpxzz3"))

(define rust-atty-0.2.14
  (crate-source "atty" "0.2.14"
                "1s7yslcs6a28c5vz7jwj63lkfgyx8mx99fdirlhi9lbhhzhrpcyr"))

(define rust-autocfg-1.1.0
  (crate-source "autocfg" "1.1.0"
                "1ylp3cb47ylzabimazvbz9ms6ap784zhb6syaz6c1jqpmcmq0s6l"))

(define rust-bitflags-1.3.2
  (crate-source "bitflags" "1.3.2"
                "12ki6w8gn1ldq7yz9y680llwk5gmrhrzszaa17g1sbrw2r2qvwxy"))

(define rust-bitflags-2.4.1
  (crate-source "bitflags" "2.4.1"
                "01ryy3kd671b0ll4bhdvhsz67vwz1lz53fz504injrd7wpv64xrj"))

(define rust-btree-range-map-0.7.2
  (crate-source "btree-range-map" "0.7.2"
                "0cvw6xnzgyi25dbc802pn8gjzqhz2axaxayarc5q1ls64ikwkr8v"))

(define rust-btree-slab-0.6.1
  (crate-source "btree-slab" "0.6.1"
                "0g7imqbf9v1p643m9bl9bkpnrf15hh4qlhljm17mq1wz0b9mcavs"))

(define rust-byteorder-1.4.3
  (crate-source "byteorder" "1.4.3"
                "0456lv9xi1a5bcm32arknf33ikv76p3fr9yzki4lb2897p2qkh8l"))

(define rust-capng-0.2.2
  (crate-source "capng" "0.2.2"
                "0x95j3fn8f2ra6d63rxk2phd9y7mjlfi41i6wi1kcq1kh92fky7n"))

(define rust-cc-1.0.79
  (crate-source "cc" "1.0.79"
                "07x93b8zbf3xc2dggdd460xlk1wg8lxm6yflwddxj8b15030klsh"))

(define rust-cc-traits-2.0.0
  (crate-source "cc-traits" "2.0.0"
                "1db2m7drl9w3yda4ybxvhykz45krqrlapcg16wkm4jpg67ph60q6"))

(define rust-cfg-if-1.0.0
  (crate-source "cfg-if" "1.0.0"
                "1za0vb97n4brpzpv8lsbnzmq5r8f2b0cpqqr0sy8h5bn751xxwds"))

(define rust-clap-4.3.11
  (crate-source "clap" "4.3.11"
                "0pd0chvzszqjczhc407b5b5w7mkybq81nizx721vnzdlgz6fah0n"))

(define rust-clap-builder-4.3.11
  (crate-source "clap_builder" "4.3.11"
                "0ay701xxriz1blywcw30261xingsq7y7fnpkafdszvi7slw93icq"))

(define rust-clap-derive-4.3.2
  (crate-source "clap_derive" "4.3.2"
                "0pw2bc8i7cxfrmwpa5wckx3fbw8s019nn7cgkv1yxmlsh4m2pkdq"))

(define rust-clap-lex-0.5.0
  (crate-source "clap_lex" "0.5.0"
                "06vcvpvp65qggc5agbirzqk2di00gxg6vazzc3qlwzkw70qxm9id"))

(define rust-cobs-0.2.3
  (crate-source "cobs" "0.2.3"
                "05gd16mws4yd63h8jr3p08in8y8w21rpjp5jb55hzl9bgalh5fk7"))

(define rust-colorchoice-1.0.0
  (crate-source "colorchoice" "1.0.0"
                "1ix7w85kwvyybwi2jdkl3yva2r2bvdcc3ka2grjfzfgrapqimgxc"))

(define rust-critical-section-1.1.2
  (crate-source "critical-section" "1.1.2"
                "05pj0pvkdyc9r30xxabam4n8zxdbzxcddr0gdypajcbqjgwgynbh"))

(define rust-env-logger-0.8.4
  (crate-source "env_logger" "0.8.4"
                "1qzw8g11dbdfi7ixm44ldykwcqsxqkh8vx5cgpd88zmclgz8g4d1"))

(define rust-errno-0.3.1
  (crate-source "errno" "0.3.1"
                "0fp7qy6fwagrnmi45msqnl01vksqwdb2qbbv60n9cz7rf0xfrksb"))

(define rust-errno-dragonfly-0.1.2
  (crate-source "errno-dragonfly" "0.1.2"
                "1grrmcm6q8512hkq5yzch3yv8wafflc2apbmsaabiyk44yqz2s5a"))

(define rust-error-chain-0.12.4
  (crate-source "error-chain" "0.12.4"
                "1z6y5isg0il93jp287sv7pn10i4wrkik2cpyk376wl61rawhcbrd"))

(define rust-futures-0.3.21
  (crate-source "futures" "0.3.21"
                "17id2zvn2acny759indn6yj2acfa6lhkwzaidxr2pqfiaigycgzp"))

(define rust-futures-channel-0.3.21
  (crate-source "futures-channel" "0.3.21"
                "0420lz2fmxa356ax1rp2sqi7b27ykfhvq4w9f1sla4hlp7j3q263"))

(define rust-futures-core-0.3.21
  (crate-source "futures-core" "0.3.21"
                "1lqhc6mqklh5bmkpr77p42lqwjj8gaskk5ba2p3kl1z4nw2gs28c"))

(define rust-futures-executor-0.3.21
  (crate-source "futures-executor" "0.3.21"
                "19mq96kwgf06axgdc2fbrjhqzdnxww9vw6cz8b82gqr9z86bj84l"))

(define rust-futures-io-0.3.21
  (crate-source "futures-io" "0.3.21"
                "0swn29fysas36ikk5aw55104fi98117amvgxw9g96pjs5ab4ah7w"))

(define rust-futures-macro-0.3.21
  (crate-source "futures-macro" "0.3.21"
                "04pmj5xfk5rdhlj69wc7w3zvdg3xardg8srig96lszrk00wf3h9k"))

(define rust-futures-sink-0.3.21
  (crate-source "futures-sink" "0.3.21"
                "0s58gx5yw1a21xviw2qgc0wzk225vgn4kbzddrp141m3kw9kw5i1"))

(define rust-futures-task-0.3.21
  (crate-source "futures-task" "0.3.21"
                "0skpiz2ljisywajv79p70yapfwhkqhb39wxy3f09v47mdfbnmijp"))

(define rust-futures-util-0.3.21
  (crate-source "futures-util" "0.3.21"
                "0sh3wqi8p36csjffy0irq8nlx9shqxp7z4dsih6bknarsvaspdyq"))

(define rust-getrandom-0.2.15
  (crate-source "getrandom" "0.2.15"
                "1mzlnrb3dgyd1fb84gvw10pyr8wdqdl4ry4sr64i1s8an66pqmn4"))

(define rust-hash32-0.2.1
  (crate-source "hash32" "0.2.1"
                "0rrbv5pc5b1vax6j6hk7zvlrpw0h6aybshxy9vbpgsrgfrc5zhxh"))

(define rust-heapless-0.7.16
  (crate-source "heapless" "0.7.16"
                "0hq7ifnzpdj9rc06rhys4qa3qkr6q3k01kwfca0ak7lbl4jbq16v"))

(define rust-heck-0.4.1
  (crate-source "heck" "0.4.1"
                "1a7mqsnycv5z4z5vnv1k34548jzmc0ajic7c1j8jsaspnhw5ql4m"))

(define rust-hermit-abi-0.1.19
  (crate-source "hermit-abi" "0.1.19"
                "0cxcm8093nf5fyn114w8vxbrbcyvv91d4015rdnlgfll7cs6gd32"))

(define rust-hermit-abi-0.3.2
  (crate-source "hermit-abi" "0.3.2"
                "12v66gy77sqrgmjlx01w9p054nvz4mnhbd6xaazkxnddrp448ca4"))

(define rust-hostname-0.3.1
  (crate-source "hostname" "0.3.1"
                "0rz8yf70cvzl3nry71m4bz9w6x4j9kdz3qng6pnwhk2h20z1qwrw"))

(define rust-humantime-2.1.0
  (crate-source "humantime" "2.1.0"
                "1r55pfkkf5v0ji1x6izrjwdq9v6sc7bv99xj6srywcar37xmnfls"))

(define rust-is-terminal-0.4.9
  (crate-source "is-terminal" "0.4.9"
                "12xgvc7nsrp3pn8hcxajfhbli2l5wnh3679y2fmky88nhj4qj26b"))

(define rust-itoa-1.0.2
  (crate-source "itoa" "1.0.2"
                "13ap85z7slvma9c36bzi7h5j66dm5sxm4a2g7wiwxbsh826nfb0i"))

(define rust-libc-0.2.177
  (crate-source "libc" "0.2.177"
                "0xjrn69cywaii1iq2lib201bhlvan7czmrm604h5qcm28yps4x18"))

(define rust-libseccomp-sys-0.2.1
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "libseccomp-sys" "0.2.1"
                "0f6iw3qsww1dkrx49wh8vmda198i7galfnvfgjc52wj6mpabnz4s"))

(define rust-linux-raw-sys-0.4.5
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "linux-raw-sys" "0.4.5"
                "00w52pb2cb4b2880ksyzagmzbyjdmp9ac0w3qfvjv3453fnzvg2p"))

(define rust-lock-api-0.4.10
  (crate-source "lock_api" "0.4.10"
                "05nd9nzxqidg24d1k8y5vlc8lz9gscpskrikycib46qbl8brgk61"))

(define rust-log-0.4.17
  (crate-source "log" "0.4.17"
                "0biqlaaw1lsr8bpnmbcc0fvgjj34yy79ghqzyi0ali7vgil2xcdb"))

(define rust-match-cfg-0.1.0
  (crate-source "match_cfg" "0.1.0"
                "1r5j3zqc3qr8ybcx95bk8q57mkizmgmffj5lmicd4i8d9riyigpz"))

(define rust-memchr-2.5.0
  (crate-source "memchr" "2.5.0"
                "0vanfk5mzs1g1syqnj03q8n0syggnhn55dq535h2wxr7rwpfbzrd"))

(define rust-num-cpus-1.13.1
  (crate-source "num_cpus" "1.13.1"
                "18apx62z4j4lajj2fi6r1i8slr9rs2d0xrbj2ls85qfyxck4brhr"))

(define rust-num-threads-0.1.6
  (crate-source "num_threads" "0.1.6"
                "0i5vmffsv6g79z869flp1sja69g1gapddjagdw1k3q9f3l2cw698"))

(define rust-once-cell-1.18.0
  (crate-source "once_cell" "1.18.0"
                "0vapcd5ambwck95wyz3ymlim35jirgnqn9a0qmi19msymv95v2yx"))

(define rust-pin-project-lite-0.2.9
  (crate-source "pin-project-lite" "0.2.9"
                "05n1z851l356hpgqadw4ar64mjanaxq1qlwqsf2k05ziq8xax9z0"))

(define rust-pin-utils-0.1.0
  (crate-source "pin-utils" "0.1.0"
                "117ir7vslsl2z1a7qzhws4pd01cg2d3338c47swjyvqv2n60v1wb"))

(define rust-postcard-1.0.6
  (crate-source "postcard" "1.0.6"
                "1sza4l5rbha2ffvi4l0w7c9ihxk2i6v4i6bl2g8kq79i6a975vn9"))

(define rust-ppv-lite86-0.2.20
  (crate-source "ppv-lite86" "0.2.20"
                "017ax9ssdnpww7nrl1hvqh2lzncpv04nnsibmnw9nxjnaqlpp5bp"))

(define rust-proc-macro2-1.0.103
  (crate-source "proc-macro2" "1.0.103"
                "1s29bz20xl2qk5ffs2mbdqknaj43ri673dz86axdbf47xz25psay"))

(define rust-quote-1.0.42
  (crate-source "quote" "1.0.42"
                "0zq6yc7dhpap669m27rb4qfbiywxfah17z6fwvfccv3ys90wqf53"))

(define rust-rand-0.8.5
  (crate-source "rand" "0.8.5"
                "013l6931nn7gkc23jz5mm3qdhf93jjf0fg64nz2lp4i51qd8vbrl"))

(define rust-rand-chacha-0.3.1
  (crate-source "rand_chacha" "0.3.1"
                "123x2adin558xbhvqb8w4f6syjsdkmqff8cxwhmjacpsl1ihmhg6"))

(define rust-rand-core-0.6.4
  (crate-source "rand_core" "0.6.4"
                "0b4j2v4cb5krak1pv6kakv4sz6xcwbrmy2zckc32hsigbrwy82zc"))

(define rust-range-traits-0.3.2
  (crate-source "range-traits" "0.3.2"
                "1ay8ghrp7phr8z1l2kg9fcszwjki5d0s5wfzqw9sjvyp5mrq21fj"))

(define rust-regex-1.6.0
  (crate-source "regex" "1.6.0"
                "12wqvyh4i75j7pc8sgvmqh4yy3qaj4inc4alyv1cdf3lf4kb6kjc"))

(define rust-regex-syntax-0.6.27
  (crate-source "regex-syntax" "0.6.27"
                "0i32nnvyzzkvz1rqp2qyfxrp2170859z8ck37jd63c8irrrppy53"))

(define rust-rustc-version-0.4.0
  (crate-source "rustc_version" "0.4.0"
                "0rpk9rcdk405xhbmgclsh4pai0svn49x35aggl4nhbkd4a2zb85z"))

(define rust-rustix-0.38.7
  (crate-source "rustix" "0.38.7"
                "1683wxw09rxjv7agbxk6v7bxv6d5zk5scczm0l0al1gbvkmr2a0p"))

(define rust-scopeguard-1.2.0
  (crate-source "scopeguard" "1.2.0"
                "0jcz9sd47zlsgcnm1hdw0664krxwb5gczlif4qngj2aif8vky54l"))

(define rust-semver-1.0.18
  (crate-source "semver" "1.0.18"
                "0659sqgnaqx42nj7n5kh3z35g3jvczsw572jhir4ibys555knadh"))

(define rust-serde-1.0.168
  (crate-source "serde" "1.0.168"
                "1br697rmgkfm1p578midw90s7wwkpr1wicq8s7g6f0vj92azh56n"))

(define rust-serde-derive-1.0.168
  (crate-source "serde_derive" "1.0.168"
                "0hfnd7c6i7vbbcfpzp3if9sr1lg25qajfkysfx0y9266g2b5iznl"))

(define rust-slab-0.4.7
  (crate-source "slab" "0.4.7"
                "1vyw3rkdfdfkzfa1mh83s237sll8v5kazfwxma60bq4b59msf526"))

(define rust-smallvec-1.13.2
  (crate-source "smallvec" "1.13.2"
                "0rsw5samawl3wsw6glrsb127rx6sh89a8wyikicw6dkdcjd1lpiw"))

(define rust-spin-0.9.8
  (crate-source "spin" "0.9.8"
                "0rvam5r0p3a6qhc18scqpvpgb3ckzyqxpgdfyjnghh8ja7byi039"))

(define rust-stable-deref-trait-1.2.0
  (crate-source "stable_deref_trait" "1.2.0"
                "1lxjr8q2n534b2lhkxd6l6wcddzjvnksi58zv11f9y0jjmr15wd8"))

(define rust-strsim-0.10.0
  (crate-source "strsim" "0.10.0"
                "08s69r4rcrahwnickvi0kq49z524ci50capybln83mg6b473qivk"))

(define rust-syn-1.0.98
  (crate-source "syn" "1.0.98"
                "1pbklw6fnwwgrkj8qz3wcjfggmn7vmyln44gg0yc5r2dj25fy2n5"))

(define rust-syn-2.0.111
  (crate-source "syn" "2.0.111"
                "11rf9l6435w525vhqmnngcnwsly7x4xx369fmaqvswdbjjicj31r"))

(define rust-syslog-6.1.1
  (crate-source "syslog" "6.1.1"
                "1lvs8ld2ps38yll29fryqwr45axm55vf46b5zvx24lbrbddykiyz"))

(define rust-termcolor-1.1.3
  (crate-source "termcolor" "1.1.3"
                "0mbpflskhnz3jf312k50vn0hqbql8ga2rk0k79pkgchip4q4vcms"))

(define rust-thiserror-2.0.17
  (crate-source "thiserror" "2.0.17"
                "1j2gixhm2c3s6g96vd0b01v0i0qz1101vfmw0032mdqj1z58fdgn"))

(define rust-thiserror-impl-2.0.17
  (crate-source "thiserror-impl" "2.0.17"
                "04y92yjwg1a4piwk9nayzjfs07sps8c4vq9jnsfq9qvxrn75rw9z"))

(define rust-time-0.3.11
  (crate-source "time" "0.3.11"
                "05rjpgfsq6gvizn89ydwwmy0ihgfvikxcwq8bz09dw5jvi0izjbj"))

(define rust-unicode-ident-1.0.2
  (crate-source "unicode-ident" "1.0.2"
                "19zf5lzhzix2s35lp5lckdy90sw0kfi5a0ii49d24dcj7yk1pihm"))

(define rust-utf8parse-0.2.1
  (crate-source "utf8parse" "0.2.1"
                "02ip1a0az0qmc2786vxk2nqwsgcwf17d3a38fkf0q7hrmwh9c6vi"))

(define rust-uuid-1.11.0
  (crate-source "uuid" "1.11.0"
                "0sj4l28lif2wm4xrafdfgqjywjzv43wzp8nii9a4i539myhg1igq"))

(define rust-version-check-0.9.4
  (crate-source "version_check" "0.9.4"
                "0gs8grwdlgh0xq660d7wr80x14vxbizmd8dbp29p2pdncx8lp1s9"))

(define rust-vhost-0.16.0
  (crate-source "vhost" "0.16.0"
                "11mcbgv5vrsaz8nw57y0gc6fzn47g1mdp83012d4wr580dr6b47f"))

(define rust-vhost-user-backend-0.22.0
  (crate-source "vhost-user-backend" "0.22.0"
                "03yaksf9b2kc14x7gdkwwxfzmaqp196609iymm97flzvv21mk4nm"))

(define rust-virtio-bindings-0.2.7
  (crate-source "virtio-bindings" "0.2.7"
                "0s485wb9bnc8a5j6aq1vyspf3k35jja7lbjn7db7hamzrw4iy7q9"))

(define rust-virtio-queue-0.17.0
  (crate-source "virtio-queue" "0.17.0"
                "1bwbd22jwbj23d513mnq26b8ph7kgwdzz60xnkfmy5pd697hhn73"))

(define rust-vm-memory-0.17.1
  (crate-source "vm-memory" "0.17.1"
                "103kgafjwicn7287jfw2dxmcfvjjpy193pbw6z9sp73896h4i4zk"))

(define rust-vmm-sys-util-0.15.0
  (crate-source "vmm-sys-util" "0.15.0"
                "0bv4l7ihgg0dlqbrdgxlm41mn5dyy6yazyf24xl1g98pyvyn4v2h"))

(define rust-wasi-0.11.0+wasi-snapshot-preview1
  (crate-source "wasi" "0.11.0+wasi-snapshot-preview1"
                "08z4hxwkpdpalxjps1ai9y7ihin26y9f476i53dv98v45gkqg3cw"))

(define rust-winapi-0.3.9
  (crate-source "winapi" "0.3.9"
                "06gl025x418lchw1wxj64ycr7gha83m44cjr5sarhynd9xkrm0sw"))

(define rust-winapi-i686-pc-windows-gnu-0.4.0
  (crate-source "winapi-i686-pc-windows-gnu" "0.4.0"
                "1dmpa6mvcvzz16zg6d5vrfy4bxgg541wxrcip7cnshi06v38ffxc"))

(define rust-winapi-util-0.1.5
  (crate-source "winapi-util" "0.1.5"
                "0y71bp7f6d536czj40dhqk0d55wfbbwqfp2ymqf1an5ibgl6rv3h"))

(define rust-winapi-x86-64-pc-windows-gnu-0.4.0
  (crate-source "winapi-x86_64-pc-windows-gnu" "0.4.0"
                "0gqq64czqb64kskjryj8isp62m2sgvx25yyj3kpc2myh85w24bki"))

(define rust-windows-sys-0.48.0
  ;; TODO REVIEW: Check bundled sources.
  (crate-source "windows-sys" "0.48.0"
                "1aan23v5gs7gya1lc46hqn9mdh8yph3fhxmhxlw36pn6pqc28zb7"))

(define rust-windows-targets-0.48.1
  (crate-source "windows-targets" "0.48.1"
                "0pz9ad4mpp06h80hkmzlib78b5r9db7isycy1gr9j17pj1sb3m05"))

(define rust-windows-aarch64-gnullvm-0.48.0
  (crate-source "windows_aarch64_gnullvm" "0.48.0"
                "1g71yxi61c410pwzq05ld7si4p9hyx6lf5fkw21sinvr3cp5gbli"))

(define rust-windows-aarch64-msvc-0.48.0
  (crate-source "windows_aarch64_msvc" "0.48.0"
                "1wvwipchhywcjaw73h998vzachf668fpqccbhrxzrz5xszh2gvxj"))

(define rust-windows-i686-gnu-0.48.0
  (crate-source "windows_i686_gnu" "0.48.0"
                "0hd2v9kp8fss0rzl83wzhw0s5z8q1b4875m6s1phv0yvlxi1jak2"))

(define rust-windows-i686-msvc-0.48.0
  (crate-source "windows_i686_msvc" "0.48.0"
                "004fkyqv3if178xx9ksqc4qqv8sz8n72mpczsr2vy8ffckiwchj5"))

(define rust-windows-x86-64-gnu-0.48.0
  (crate-source "windows_x86_64_gnu" "0.48.0"
                "1cblz5m6a8q6ha09bz4lz233dnq5sw2hpra06k9cna3n3xk8laya"))

(define rust-windows-x86-64-gnullvm-0.48.0
  (crate-source "windows_x86_64_gnullvm" "0.48.0"
                "0lxryz3ysx0145bf3i38jkr7f9nxiym8p3syklp8f20yyk0xp5kq"))

(define rust-windows-x86-64-msvc-0.48.0
  (crate-source "windows_x86_64_msvc" "0.48.0"
                "12ipr1knzj2rwjygyllfi5mkd0ihnbi3r61gag5n2jgyk5bmyl8s"))

(define rust-zerocopy-0.7.35
  (crate-source "zerocopy" "0.7.35"
                "1w36q7b9il2flg0qskapgi9ymgg7p985vniqd09vi0mwib8lz6qv"))

(define rust-zerocopy-derive-0.7.35
  (crate-source "zerocopy-derive" "0.7.35"
                "0gnf2ap2y92nwdalzz3x7142f2b83sni66l39vxp2ijd6j080kzs"))


(define-cargo-inputs lookup-cargo-inputs
  (virtiofsd =>
    (list
     rust-aho-corasick-0.7.18
     rust-anstream-0.3.2
     rust-anstyle-1.0.1
     rust-anstyle-parse-0.2.1
     rust-anstyle-query-1.0.0
     rust-anstyle-wincon-1.0.1
     rust-arc-swap-1.5.0
     rust-atomic-polyfill-0.1.11
     rust-atty-0.2.14
     rust-autocfg-1.1.0
     rust-bitflags-1.3.2
     rust-bitflags-2.4.1
     rust-btree-range-map-0.7.2
     rust-btree-slab-0.6.1
     rust-byteorder-1.4.3
     rust-capng-0.2.2
     rust-cc-1.0.79
     rust-cc-traits-2.0.0
     rust-cfg-if-1.0.0
     rust-clap-4.3.11
     rust-clap-builder-4.3.11
     rust-clap-derive-4.3.2
     rust-clap-lex-0.5.0
     rust-cobs-0.2.3
     rust-colorchoice-1.0.0
     rust-critical-section-1.1.2
     rust-env-logger-0.8.4
     rust-errno-0.3.1
     rust-errno-dragonfly-0.1.2
     rust-error-chain-0.12.4
     rust-futures-0.3.21
     rust-futures-channel-0.3.21
     rust-futures-core-0.3.21
     rust-futures-executor-0.3.21
     rust-futures-io-0.3.21
     rust-futures-macro-0.3.21
     rust-futures-sink-0.3.21
     rust-futures-task-0.3.21
     rust-futures-util-0.3.21
     rust-getrandom-0.2.15
     rust-hash32-0.2.1
     rust-heapless-0.7.16
     rust-heck-0.4.1
     rust-hermit-abi-0.1.19
     rust-hermit-abi-0.3.2
     rust-hostname-0.3.1
     rust-humantime-2.1.0
     rust-is-terminal-0.4.9
     rust-itoa-1.0.2
     rust-libc-0.2.177
     rust-libseccomp-sys-0.2.1
     rust-linux-raw-sys-0.4.5
     rust-lock-api-0.4.10
     rust-log-0.4.17
     rust-match-cfg-0.1.0
     rust-memchr-2.5.0
     rust-num-cpus-1.13.1
     rust-num-threads-0.1.6
     rust-once-cell-1.18.0
     rust-pin-project-lite-0.2.9
     rust-pin-utils-0.1.0
     rust-postcard-1.0.6
     rust-ppv-lite86-0.2.20
     rust-proc-macro2-1.0.103
     rust-quote-1.0.42
     rust-rand-0.8.5
     rust-rand-chacha-0.3.1
     rust-rand-core-0.6.4
     rust-range-traits-0.3.2
     rust-regex-1.6.0
     rust-regex-syntax-0.6.27
     rust-rustc-version-0.4.0
     rust-rustix-0.38.7
     rust-scopeguard-1.2.0
     rust-semver-1.0.18
     rust-serde-1.0.168
     rust-serde-derive-1.0.168
     rust-slab-0.4.7
     rust-smallvec-1.13.2
     rust-spin-0.9.8
     rust-stable-deref-trait-1.2.0
     rust-strsim-0.10.0
     rust-syn-1.0.98
     rust-syn-2.0.111
     rust-syslog-6.1.1
     rust-termcolor-1.1.3
     rust-thiserror-2.0.17
     rust-thiserror-impl-2.0.17
     rust-time-0.3.11
     rust-unicode-ident-1.0.2
     rust-utf8parse-0.2.1
     rust-uuid-1.11.0
     rust-version-check-0.9.4
     rust-vhost-0.16.0
     rust-vhost-user-backend-0.22.0
     rust-virtio-bindings-0.2.7
     rust-virtio-queue-0.17.0
     rust-vm-memory-0.17.1
     rust-vmm-sys-util-0.15.0
     rust-wasi-0.11.0+wasi-snapshot-preview1
     rust-winapi-0.3.9
     rust-winapi-i686-pc-windows-gnu-0.4.0
     rust-winapi-util-0.1.5
     rust-winapi-x86-64-pc-windows-gnu-0.4.0
     rust-windows-sys-0.48.0
     rust-windows-targets-0.48.1
     rust-windows-aarch64-gnullvm-0.48.0
     rust-windows-aarch64-msvc-0.48.0
     rust-windows-i686-gnu-0.48.0
     rust-windows-i686-msvc-0.48.0
     rust-windows-x86-64-gnu-0.48.0
     rust-windows-x86-64-gnullvm-0.48.0
     rust-windows-x86-64-msvc-0.48.0
     rust-zerocopy-0.7.35
     rust-zerocopy-derive-0.7.35)))
