%global commit 39a6e6daaf029fb0a083777679a15ea2c18f72de
%global shortcommit 39a6e6d
%global commitdate 20250324

Name:           qbootctl
Version:        0^%{commitdate}git%{shortcommit}
Release:        1%{?dist}
Summary:        Qualcomm A/B slot control (boot_control HAL port for Linux)
License:        GPL-3.0-only
URL:            https://github.com/linux-msm/qbootctl
Source0:        %{url}/archive/%{commit}/qbootctl-%{commit}.tar.gz

BuildRequires:  gcc
BuildRequires:  meson
BuildRequires:  kernel-headers

%description
Reads and sets the A/B slot attributes that Qualcomm bootloaders keep in the
GPT, like Android's boot_control HAL. Used on the Nothing Phone (4a) to mark a
good boot as successful, so the bootloader's retry counter stops counting down.

%prep
%autosetup -n qbootctl-%{commit}

%build
%meson
%meson_build

%install
%meson_install

%files
%license LICENSE
%doc README.md
%{_bindir}/qbootctl
