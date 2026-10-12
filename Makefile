PREFIX ?= /usr
SYSCONFDIR ?= /etc
SYSTEMDDIR ?= $(PREFIX)/lib/systemd/system
DOCDIR ?= $(PREFIX)/share/doc/net-failover-watchdog
LICENSEDIR ?= $(PREFIX)/share/licenses/net-failover-watchdog
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib/net-failover-watchdog

.PHONY: all test check install uninstall clean

all:
	@echo "Nothing to compile (shell-based daemon). Run 'make check' to run tests or 'make install' to install."

test: check

check:
	@bash ./tests/run_tests.sh

install:
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 net-failover-watchdog "$(DESTDIR)$(BINDIR)/net-failover-watchdog"
	install -m 755 net-failover-watchdog-ctl "$(DESTDIR)$(BINDIR)/net-failover-watchdog-ctl"

	install -d "$(DESTDIR)$(LIBDIR)"
	install -m 644 net-failover-common.sh "$(DESTDIR)$(LIBDIR)/net-failover-common.sh"

	install -d "$(DESTDIR)$(SYSTEMDDIR)"
	install -m 644 net-failover-watchdog.service "$(DESTDIR)$(SYSTEMDDIR)/net-failover-watchdog.service"

	install -d "$(DESTDIR)$(SYSCONFDIR)"
	install -m 644 net-failover-watchdog.conf "$(DESTDIR)$(SYSCONFDIR)/net-failover-watchdog.conf"

	install -d "$(DESTDIR)$(DOCDIR)"
	install -m 644 99-net-failover-watchdog-sysctl.conf.example "$(DESTDIR)$(DOCDIR)/99-net-failover-watchdog-sysctl.conf.example"
	install -m 644 README.md "$(DESTDIR)$(DOCDIR)/README.md"

	install -d "$(DESTDIR)$(LICENSEDIR)"
	install -m 644 LICENSE "$(DESTDIR)$(LICENSEDIR)/LICENSE"

	# Create the drop-in config directory for runtime priority overrides
	install -d "$(DESTDIR)$(SYSCONFDIR)/net-failover-watchdog.d"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/net-failover-watchdog"
	rm -f "$(DESTDIR)$(BINDIR)/net-failover-watchdog-ctl"
	rm -rf "$(DESTDIR)$(LIBDIR)"
	rm -f "$(DESTDIR)$(SYSTEMDDIR)/net-failover-watchdog.service"
	rm -f "$(DESTDIR)$(SYSCONFDIR)/net-failover-watchdog.conf"
	rm -rf "$(DESTDIR)$(DOCDIR)"
	rm -rf "$(DESTDIR)$(LICENSEDIR)"

clean:
	rm -rf /tmp/net-watchdog-test.*
