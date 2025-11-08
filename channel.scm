(use-modules (guix ci))
(list
  (channel-with-substitutes-available
    %default-guix-channel
    "https://ci.guix.gnu.org")
  (channel
    (name 'guix)
    (url "https://codeberg.org/guix/guix.git")
    (branch "master")
    (introduction
      (make-channel-introduction
        "9edb3f66fd807b096b48283debdcddccfea34bad"
        (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D E643 A2A0 6DF2 A33A 54FA"))))

  (channel
    (name 'guix-xlibre)
    (url "https://gitlab.vulnix.sh/spacecadet/guix-xlibre.git")
    (branch "master"))
(channel
        (name 'small-guix)
        (url "https://codeberg.org/fishinthecalculator/small-guix.git")
        (branch "main")
        ;; Enable signature verification:
        (introduction
         (make-channel-introduction
          "f260da13666cd41ae3202270784e61e062a3999c"
          (openpgp-fingerprint
           "8D10 60B9 6BB8 292E 829B  7249 AED4 1CC1 93B7 01E2"))))
 
  (channel
   (name 'saayix)
   (branch "main")
   (url "https://codeberg.org/look/saayix")
   (introduction
    (make-channel-introduction
     "12540f593092e9a177eb8a974a57bb4892327752"
     (openpgp-fingerprint
      "3FFA 7335 973E 0A49 47FC  0A8C 38D5 96BE 07D3 34AB"))))

 (channel
    (name 'nonguix)
    (url "https://gitlab.com/nonguix/nonguix")
    (branch "master")
    (commit "f9a27a679bd02fcebae69833b14ef54dff82ccf1")
    (introduction
      (make-channel-introduction
        "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
        (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29 12AF 6F51 20A0 22FB B2D5")))))
