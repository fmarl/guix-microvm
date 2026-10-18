(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix")
       (introduction
        (make-channel-introduction
         "1fc71fd013a752600de04e3f5a5757fc1eafc5e7"
         (openpgp-fingerprint
          "2841 9AC6 5038 7440 C7E9  2FFA 2208 D209 58C1 DEB0"))))
      (channel
       (name 'guix-cage)
       (url "https://github.com/fmarl/guix-cage")
       (branch "main")
       (introduction
        (make-channel-introduction
         "56a634b5aae8a3c4e12a292ba87ac336a27ddcbc"
         (openpgp-fingerprint
          "F2E3 8B47 808B AF7B 81D5  B27F 52C5 7B54 89B5 819D")))))
