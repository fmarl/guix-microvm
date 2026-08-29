(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix")
       (branch "master")
       (commit "88986acb4b11a17e603d97c02a7a2909d2ac86ea")
       (introduction
        (make-channel-introduction
         "1fc71fd013a752600de04e3f5a5757fc1eafc5e7"
         (openpgp-fingerprint
          "2841 9AC6 5038 7440 C7E9  2FFA 2208 D209 58C1 DEB0"))))
      (channel
       (name 'sagittarius)
       (url "https://codeberg.org/fmarl/sagittarius")
       (branch "main")
       (commit "7b613a28b0d92feec0c7aae409eece6e69a9ccf5")
       (introduction
        (make-channel-introduction
         "c2302ace8d0b0d16a01668399889c9d796af5777"
         (openpgp-fingerprint
          "F2E3 8B47 808B AF7B 81D5  B27F 52C5 7B54 89B5 819D")))))
