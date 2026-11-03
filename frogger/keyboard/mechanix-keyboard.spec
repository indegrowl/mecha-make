%global commit ea50e90b909b24e9f874037bbe0c55616e95e7b8
%global shortcommit ea50e90

# The Mecha repo's newest build (0.1.0-3, 2026-10-08) predates the audio
# feedback work merged on main; this builds main until the repo catches up.
Name:           mechanix-keyboard
Version:        0.1.0
Release:        5.frogger.git%{shortcommit}
Summary:        Mechanix on-screen keyboard
License:        BSD-3-Clause
URL:            https://github.com/mecha-org/mechanix-keyboard
Source0:        %{url}/archive/%{commit}/mechanix-keyboard-%{commit}.tar.gz
# Key sound off unless MECHANIX_KBD_SOUND=1: its open stream crackled the speakers.
Patch0:         0001-key-sound-off-by-default.patch

BuildRequires:  cargo
BuildRequires:  rust
BuildRequires:  gcc
BuildRequires:  git
BuildRequires:  pkgconf-pkg-config
BuildRequires:  alsa-lib-devel
BuildRequires:  libxkbcommon-devel
BuildRequires:  wayland-devel
BuildRequires:  mesa-libgbm-devel

%description
On-screen keyboard for the Mechanix shell (input-method-v2 with a
virtual-keyboard-v1 fallback), with press animation and optional key sounds
(MECHANIX_KBD_SOUND=1).

%prep
%autosetup -p1 -n mechanix-keyboard-%{commit}

%build
# Dependencies (including the mecha-wayland git branch) come from the network,
# pinned by Cargo.lock.
cargo build --release --locked

%install
install -Dm755 target/release/mechanix-keyboard %{buildroot}%{_bindir}/mechanix-keyboard

%files
%license LICENSE
%doc README.md
%{_bindir}/mechanix-keyboard
