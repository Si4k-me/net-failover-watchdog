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
    "${pkgname}.service"
    "${pkgname}.conf"
    "99-${pkgname}-sysctl.conf.example"
    "LICENSE"
    "README.md"
)
sha256sums=(
    '781870ab66856b0167ff724ab5a95c490c48dd579e7145c9dc78e42ab79c5e5e'
    '05e3f9fbbb56dae2fad28cbdd3c9127abb7201703f84d8eced7c91ba4fda8987'
    'b8bdc6cae72dbaa418595e6596916137b2ac8c8272572dc511220a4733f9f35c'
    'cfb6ec27d8f6e987f710aac9240b7db73ddf46b774a9fedd1aa44b4e7ed8aa8b'
    'c3761502e5eae5ed190db46745a02b910686d63f69cd8edf229bb3e593ef4d7c'
    'dc32706fbbe2fc7204d78b73db8cd57fa7438c92416e480d0959d54525f33b1c'
    '3b0599d6d0d1d0462c5f23f585f58d92c131904cb5ae2b6ff458d215c5f15a88'
)

package() {
    install -Dm755 "${srcdir}/${pkgname}" "${pkgdir}/usr/bin/${pkgname}"
    install -Dm755 "${srcdir}/${pkgname}-ctl" "${pkgdir}/usr/bin/${pkgname}-ctl"
    install -Dm644 "${srcdir}/${pkgname}.service" "${pkgdir}/usr/lib/systemd/system/${pkgname}.service"
    install -Dm644 "${srcdir}/${pkgname}.conf" "${pkgdir}/etc/${pkgname}.conf"
    install -dm755 "${pkgdir}/etc/${pkgname}.d"
    install -Dm644 "${srcdir}/99-${pkgname}-sysctl.conf.example" "${pkgdir}/usr/share/doc/${pkgname}/99-${pkgname}-sysctl.conf.example"
    install -Dm644 "${srcdir}/README.md" "${pkgdir}/usr/share/doc/${pkgname}/README.md"
    install -Dm644 "${srcdir}/LICENSE" "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
