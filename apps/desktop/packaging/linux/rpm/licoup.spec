Name: licoup
Version: ${LICOUP_VERSION}
Release: 1%{?dist}
Summary: Official LicoMesh client
License: AGPL-3.0-or-later
URL: https://github.com/LicoLand/LicoUp
BuildArch: ${LICOUP_RPM_ARCH}
Requires: gtk3, glibc, libstdc++

%description
LicoUp manages local AI agent conversations and secure peer connectivity.

%install
mkdir -p %{buildroot}%{_libexecdir}/licoup %{buildroot}%{_bindir}
cp -a %{_sourcedir}/bundle/. %{buildroot}%{_libexecdir}/licoup/
ln -s ../libexec/licoup/licoup %{buildroot}%{_bindir}/licoup

%files
%{_libexecdir}/licoup
%{_bindir}/licoup
