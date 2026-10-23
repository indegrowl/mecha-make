Name:           frogger-steam-padfix
Version:        2
Release:        1.frogger%{?dist}
Summary:        Hides the green seam in Steam Remote Play on the Nothing Phone (4a)
License:        MIT
Source0:        sc-padfix.c

BuildRequires:  gcc
BuildRequires:  kernel-headers

%description
LD_PRELOAD shim for Valve's ARM64 streaming_client. The client samples the
never-written padding columns of the Iris decoder's NV12 buffers, which shows
as a one-pixel green seam on the right edge; the shim paints them black.

%prep
cp %{SOURCE0} .

%build
gcc %{optflags} -fPIC -shared -o sc-padfix.so sc-padfix.c

%install
install -Dm755 sc-padfix.so %{buildroot}%{_libdir}/frogger-steam/sc-padfix.so

%files
%{_libdir}/frogger-steam/sc-padfix.so
