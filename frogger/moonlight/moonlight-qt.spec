Name:           moonlight-qt
Version:        6.2.0
Release:        1.frogger2%{?dist}
Summary:        Moonlight game streaming client, built against the Iris FFmpeg
License:        GPL-3.0-or-later
URL:            https://github.com/moonlight-stream/moonlight-qt
Source0:        MoonlightSrc-%{version}.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt6-qtdeclarative-devel
BuildRequires:  qt6-qtsvg-devel
BuildRequires:  SDL2-devel
BuildRequires:  SDL2_ttf-devel
BuildRequires:  openssl-devel
BuildRequires:  opus-devel
BuildRequires:  libdrm-devel
BuildRequires:  wayland-devel
BuildRequires:  libavcodec-free-devel
BuildRequires:  libavutil-free-devel
BuildRequires:  libswscale-free-devel

%description
Moonlight streams games from a Sunshine host. This build links the frogger
ffmpeg-free (.frogger4), whose hevc_v4l2m2m decoder runs on the Iris VPU of the
Nothing Phone (4a).

%prep
%setup -q -c

%build
qmake6 PREFIX=%{_prefix} CONFIG+=release moonlight-qt.pro
%make_build

%install
make install INSTALL_ROOT=%{buildroot}
# Started through the frogger Moonlight session (landscape gamescope); its own
# entry would open the portrait host list in Mechanix.
rm %{buildroot}%{_datadir}/applications/com.moonlight_stream.Moonlight.desktop
%files
%license LICENSE
%{_bindir}/moonlight
%{_datadir}/icons/hicolor/scalable/apps/moonlight.svg
%{_datadir}/metainfo/com.moonlight_stream.Moonlight.appdata.xml
