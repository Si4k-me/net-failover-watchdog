# Maintainer: Akshit Kamboj <akshitkamboz13@gmail.com>

pkgname=net-failover-watchdog
pkgver=1.1.0
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
sha256sums=('725e49e015e30d5e9252c65abbf44540bd15f64c9bb1141b53878b2b6f2d47ee'
            'c9438ff2f4135a43dcc048ec47b2ae082985548f41237fa53effef9e78493d84'
            'b84d82ea0f66b3e222194d29af9d8b343c3a9ba45e157cb58f2081761515c7a0'
            'b8bdc6cae72dbaa418595e6596916137b2ac8c8272572dc511220a4733f9f35c'
            '4c2a51b27affe95159673ef66d3794bd0d2b9e04f1a8f8021d1eabd544ace64f'
            'c3761502e5eae5ed190db46745a02b910686d63f69cd8edf229bb3e593ef4d7c'
            'dc32706fbbe2fc7204d78b73db8cd57fa7438c92416e480d0959d54525f33b1c'
            'd1f25e4ca39142548ff3016a637fed1cd146a0ae0982954786bf87b197779dca')

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
