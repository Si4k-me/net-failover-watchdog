# Maintainer: Akshit Kamboj <akshitkamboz13@gmail.com>

pkgname=net-failover-watchdog
pkgver=1.0.0
pkgrel=1
pkgdesc="Health-aware Linux network failover daemon with configurable interface priorities, hysteresis, IPv4 route management and connectivity verification"
arch=('any')
url="https://github.com/Akshitkamboz13/net-failover-watchdog"
license=('MIT')
depends=('bash' 'iproute2' 'iputils' 'curl' 'util-linux' 'gawk')
optdepends=('systemd: for resolvectl DNS synchronization')
backup=('etc/net-failover-watchdog.conf')
source=(
    "${pkgname}"
    "${pkgname}-ctl"
    "net-failover-common.sh"
    "${pkgname}.service"
    "${pkgname}.conf"
    "99-${pkgname}-sysctl.conf.example"
    "LICENSE"
    "README.md"
)
sha256sums=(
    '73a6979605342ad00aef30548a40bd04c33dc6df7453f8ff02a9e92de8e70640'
    '0ad783e1b28d5402a96e504fd35e3eb4d44ebfb803eb387f1ee8c88f02feb610'
    'f6d938b06cf26ed792e192e78f7e2974ba453eb903d6e4219d2d72c0874d6a22'
    'b8bdc6cae72dbaa418595e6596916137b2ac8c8272572dc511220a4733f9f35c'
    'cfb6ec27d8f6e987f710aac9240b7db73ddf46b774a9fedd1aa44b4e7ed8aa8b'
    'c3761502e5eae5ed190db46745a02b910686d63f69cd8edf229bb3e593ef4d7c'
    'dc32706fbbe2fc7204d78b73db8cd57fa7438c92416e480d0959d54525f33b1c'
    'f68fdc06ac87cb26fc547f405515bb8033dc2fc8cabe2341686b2fff7ea74686'
)

package() {
    install -Dm755 "${srcdir}/${pkgname}" "${pkgdir}/usr/bin/${pkgname}"
    install -Dm755 "${srcdir}/${pkgname}-ctl" "${pkgdir}/usr/bin/${pkgname}-ctl"
    install -Dm644 "${srcdir}/net-failover-common.sh" "${pkgdir}/usr/lib/${pkgname}/net-failover-common.sh"
    install -Dm644 "${srcdir}/${pkgname}.service" "${pkgdir}/usr/lib/systemd/system/${pkgname}.service"
    install -Dm644 "${srcdir}/${pkgname}.conf" "${pkgdir}/etc/${pkgname}.conf"
    install -dm755 "${pkgdir}/etc/${pkgname}.d"
    install -Dm644 "${srcdir}/99-${pkgname}-sysctl.conf.example" "${pkgdir}/usr/share/doc/${pkgname}/99-${pkgname}-sysctl.conf.example"
    install -Dm644 "${srcdir}/README.md" "${pkgdir}/usr/share/doc/${pkgname}/README.md"
    install -Dm644 "${srcdir}/LICENSE" "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
