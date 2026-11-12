;; Read-only daemon handshake. No store enumeration, builds or trust changes.
(use-modules (guix store))
(with-store connection
  (unless connection (error "Guix daemon is unavailable"))
  (display "Guix daemon connection available\n"))
