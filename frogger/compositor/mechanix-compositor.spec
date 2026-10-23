%global commit c0d551b14775afa0a71e48fada4f51cb06e9768f
%global shortcommit c0d551b

# The Mecha repo's 1.0.0-2 build applies the Mecha Comet's gamut-correction
# shader (mecha-org/smithay bb3be182) to everything. The 4a's colours are
# corrected in the display hardware instead, so this builds the same source with
# smithay pinned to the commit before that shader (60aafc2b).
Name:           mechanix-compositor
Version:        1.0.0
Release:        2.frogger1.git%{shortcommit}
Summary:        Mechanix Wayland compositor, without the Comet colour matrix
License:        BSD-3-Clause
URL:            https://github.com/mecha-org/mechanix-comp
Source0:        %{url}/archive/%{commit}/mechanix-comp-%{commit}.tar.gz
Patch0:         0001-pin-smithay-before-the-comet-colour-matrix.patch

BuildRequires:  cargo
BuildRequires:  rust
BuildRequires:  gcc
BuildRequires:  git
BuildRequires:  pkgconf-pkg-config
BuildRequires:  mesa-libgbm-devel
BuildRequires:  libdrm-devel
BuildRequires:  libseat-devel
BuildRequires:  libinput-devel
BuildRequires:  systemd-devel
BuildRequires:  libxkbcommon-devel
BuildRequires:  wayland-devel

%description
The Mechanix Wayland compositor (smithay), built for the Nothing Phone (4a)
without the Mecha Comet's gamut-correction shader.

%prep
%autosetup -p1 -n mechanix-comp-%{commit}

%build
# Dependencies (smithay from git) come from the network, pinned by Cargo.lock.
cargo build --release --locked

%install
install -Dm755 target/release/compositor %{buildroot}%{_bindir}/mechanix-compositor

%files
%license LICENSE
%doc README.md
%{_bindir}/mechanix-compositor
