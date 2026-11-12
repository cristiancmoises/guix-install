# Security model / Modelo de segurança

This is privileged installation software. Review it before granting sudo. The current system path has not completed disposable-VM installation/boot qualification. Do not treat unit tests, Guix record evaluation, or screenshots as evidence that a real installation is bootable.

Este é um programa de instalação privilegiado. Revise antes de conceder sudo. O caminho System ainda não completou instalação/boot em VM descartável. Testes unitários, avaliação de registros Guix e capturas de tela não comprovam uma instalação inicializável.

## Trust and privilege

- The initial HTTPS launcher and its hosting account are trust anchors. Each payload file is additionally pinned by commit and SHA-256; hashes are not independent signatures of the launcher.
- The unchanged bundled upstream installer retains OpenPGP archive verification. Ambient `GUIX_BINARY_FILE_NAME` and overwrite/bypass variables are stripped before it runs. Its support and policy decisions remain upstream behavior.
- System channels retain their published introductions and exact compatibility commits. No `--disable-authentication`, insecure TLS, sandbox relaxation, arbitrary key authorization, or custom substitute key is added.
- The GUI runs as an ordinary user. A terminal invokes the same CLI, then sudo. There is no privileged GUI, listener, remote API, telemetry, paid service or passwordless sudo rule.
- Source directories and executable search paths must be trusted by the installing user. Do not grant access to your checkout or install while another privileged program manages disks. Root can replace mounts or executables; this tool does not claim isolation from a malicious root process.

## Disk boundaries

- Explicit whole-disk selection, ≥32 GiB, writable device, no mounted descendants, active swap or holders. Removable physical disks are allowed; loop targets are not.
- Root and live-media backing disks must resolve. Unknown roots, ambiguous kernel root specifications and unknown Secure Boot state fail closed. Live overlays unsupported by the resolver are refused rather than guessed.
- Exact `ERASE /dev/…` consent, no yes/force bypass. An identity snapshot made before consent is compared before writes: major/minor, size, disk sequence, serial and WWN.
- Exclusive root-owned installation lock. Checks reduce races but are not an atomic claim against other disk managers.
- Only run-owned mountpoints are unmounted, in reverse order. Failed unmounts preserve recovery paths. Cleanup uses `rmdir`, never recursive deletion of a possible mounted target.
- GPT creation and formatting are irreversible within this tool. Failures and interruptions may leave a partially modified disk. It does not resize existing installations or recover data.

## Credentials and local data

- Password entry uses the terminal's non-echoing password reader. OpenSSL receives input through stdin, never argv/environment. No plaintext password or verifier is logged.
- The generated configuration declares locked accounts. The salted verifier is seeded only into target `/etc/shadow`, with mode 0600, atomic replacement and fsync, after successful init. Guix's existing-entry preservation was checked with its actual account merge function; first boot remains untested.
- Keep the target disk and backups protected; SHA-512 crypt is not encryption. Configuration changes cannot protect a disk stolen without encryption.
- Command-status logs are root-readable under `/var/log/guix-install-*.log`. They include paths/device names and native exit status; they do not record a full terminal transcript. Retain them for recovery, remove manually when no longer needed.
- Bootstrap sources remain in a private temporary directory until manually removed or the OS cleans temporary files. They contain source only. No service token is distributed or committed. Maintainer publishing credentials stay outside the source tree.
- Child commands that create installed system directories run with umask 022; private log/shadow files are created explicitly with 0600. A private-state umask must not make `/etc` or `/gnu` inaccessible to installed users.

## Reporting

Report a suspected vulnerability privately to the maintainer using a forge's private vulnerability reporting when available. Do not attach passwords, tokens, private logs or personal disk inventories to public issues. Public bug reports should use synthetic devices and redacted diagnostics.

Relate suspeitas de vulnerabilidade em canal privado do mantenedor quando disponível. Não publique senhas, tokens, logs privados ou inventários pessoais de discos. Use dispositivos fictícios e diagnósticos anonimizados em issues públicas.

## 0.3.0 boundary updates

Unknown read-only device state is refused. Partition snapshots include kernel major/minor, number, device path, byte size and start sector and are revalidated before formatting/mounting. Mount access and cleanup require a matching mount ID, filesystem root and major/minor; a replaced mount is preserved for manual recovery. These checks still do not isolate operations from a malicious root process.

Read-only GUI workers never access Tk or install anything. Results are applied only on the event thread and only while the originating form generation remains current. Disk safety conclusions are not cached across installation writes.

The launcher limits parallel fetches to four. Each file retains its own hash/size checks; execution waits for every future to succeed. Failure/cancellation cancels queued work; active requests retain a bounded socket timeout. Transport timeout fallback does not permit checksum failures. Artwork is local and attributed; there are no new runtime network services or image dependencies.
