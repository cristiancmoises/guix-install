;; Upstream-only profile. Source: securityops-iso/channels.guix, 2026-11-11.
;; A commit pin does not replace authentication: keep the introduction.
(list
 (channel
  (name 'guix)
  (url "https://codeberg.org/guix/guix.git")
  (commit "b9a35ee6b53438d53d66cbe3e82f26bb22a44b5b")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D E643 A2A0 6DF2 A33A 54FA")))))
