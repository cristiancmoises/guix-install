;; Maintainer channel graph. Source: securityops-iso/channels.guix (v1.14.0).
;; A commit pin does not replace authentication: keep the introduction.
(list
 (channel
  (name 'guix)
  (url "https://git.securityops.com.br/cristiancmoises/guix.git")
  (branch "master")
  (commit "505ade83fc62b438c558653dd57f7fb3b197cc8f")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D E643 A2A0 6DF2 A33A 54FA"))))
 (channel
  (name 'nonguix)
  (url "https://git.securityops.com.br/cristiancmoises/nonguix.git")
  (branch "master")
  (commit "c241d19ff840dc75556f722b231760d119b6adea")
  (introduction
   (make-channel-introduction
    "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
    (openpgp-fingerprint
     "2A39 3FFF 68F4 EF7A 3D29 12AF 6F51 20A0 22FB B2D5"))))
 (channel
  (name 'radix)
  (url "https://git.securityops.com.br/cristiancmoises/radix.git")
  (branch "main")
  (commit "d12acbe81ae3a5ff9ad8b705a13a5d1613384df4")
  (introduction
   (make-channel-introduction
    "f9130e11e35d2c147c6764ef85542dc58dc09c4f"
    (openpgp-fingerprint
     "F164 709E 5FC7 B32B AEC7 9F37 1F2E 76AC E3F5 31C8"))))
 (channel
  (name 'rosenthal)
  (url "https://git.securityops.com.br/cristiancmoises/rosenthal.git")
  (branch "trunk")
  (commit "bfe0d7379d399c7886e7c991d0c4bd01a3dfb015")
  (introduction
   (make-channel-introduction
    "7677db76330121a901604dfbad19077893865f35"
    (openpgp-fingerprint
     "13E7 6CD6 E649 C28C 3385 4DF5 5E5A A665 6149 17F7"))))
 (channel
  (name 'small-guix)
  (url "https://git.securityops.com.br/cristiancmoises/small-guix.git")
  (branch "main")
  (commit "26cc25719837c8c914079d0df82aafb0e4c66b78")
  (introduction
   (make-channel-introduction
    "59de79f673669b798f650754b629404418464784"
    (openpgp-fingerprint
     "0CFA 43B9 AA96 42EA AF2B E983 C4C6 61C9 ECFB 46E8"))))
 (channel
  (name 'securityops)
  (url "https://git.securityops.com.br/cristiancmoises/securityops-channel.git")
  (branch "main")
  (commit "017b9e3aa09bbafca341dfba7c91ca96211e8020")
  (introduction
   (make-channel-introduction
    "fb3223f3afdc14bab294c78d88e545eda2b146d9"
    (openpgp-fingerprint
     "0CFA 43B9 AA96 42EA AF2B E983 C4C6 61C9 ECFB 46E8"))))
 (channel
  (name 'gocix)
  (url "https://git.securityops.com.br/cristiancmoises/gocix.git")
  (branch "main")
  (commit "d4beb39153608a68d2278085847cee585ca851b5")
  (introduction
   (make-channel-introduction
    "cdb78996334c4f63304ecce224e95bb96bfd4c7d"
    (openpgp-fingerprint
     "8D10 60B9 6BB8 292E 829B 7249 AED4 1CC1 93B7 01E2"))))
 (channel
  (name 'sops-guix)
  (url "https://git.securityops.com.br/cristiancmoises/sops-guix.git")
  (branch "main")
  (commit "c53e27e533836ea8595626ba6796dee5362f8c4a")
  (introduction
   (make-channel-introduction
    "0bbaf1fdd25266c7df790f65640aaa01e6d2dbc9"
    (openpgp-fingerprint
     "8D10 60B9 6BB8 292E 829B 7249 AED4 1CC1 93B7 01E2")))))
