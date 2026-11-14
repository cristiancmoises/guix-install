Name:           guix-install
Version:        0.4.1
Release:        1
Summary:        Install GNU Guix from any GNU/Linux distribution
License:        GPL-3.0-or-later
URL:            https://github.com/cristiancmoises/guix-install
Source0:        guix-install-0.4.1.tar.gz
BuildArch:      noarch
Requires:       python3 >= 3.10
Recommends:     python3-tkinter
Recommends:     sudo
Recommends:     curl
Recommends:     wget
Recommends:     gnupg
Recommends:     xz

%description
Native GUI and terminal installer for the GNU Guix package manager and for
Guix System. Plans are read-only and disk installation always requires the
exact device name, with busy and protected disks refused.

%prep
%autosetup

%build
# Pure Python runtime; nothing to compile.

%install
mkdir -p %{buildroot}%{_prefix}/lib/guix-install
cp -r guix_installer run.py vendor assets %{buildroot}%{_prefix}/lib/guix-install/
find %{buildroot}%{_prefix}/lib/guix-install -type d -name '__pycache__' -prune -exec rm -r {} +
install -Dm755 packaging/linux/guix-install %{buildroot}%{_bindir}/guix-install
install -Dm644 packaging/linux/guix-install.desktop %{buildroot}%{_datadir}/applications/guix-install.desktop
install -Dm644 assets/guix-logo.png %{buildroot}%{_datadir}/pixmaps/guix-logo.png

%files
%{_bindir}/guix-install
%{_prefix}/lib/guix-install/
%{_datadir}/applications/guix-install.desktop
%{_datadir}/pixmaps/guix-logo.png

%changelog
* Fri Nov 13 2026 Security Ops <sac@securityops.co> - 0.4.1-1
- First native RPM packaging of the 0.4.1 installer.
