PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin

# Config directory
# Use SUDO_USER's home directory if available, otherwise fall back to HOME
USER_HOME = $(shell if [ -n "$$SUDO_USER" ]; then getent passwd "$$SUDO_USER" | cut -d: -f6; else echo "$(HOME)"; fi)
XDG_CONFIG_HOME ?= $(USER_HOME)/.config
CONFIG_DIR = $(XDG_CONFIG_HOME)/dumptxt

# Install script and config
install:
	# create bin dir and install script
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 dumptxt.sh $(DESTDIR)$(BINDIR)/dumptxt

	# create config dir and install default config
	install -d $(CONFIG_DIR)
	install -m 644 config.toml $(CONFIG_DIR)/config.toml

uninstall:
	# remove script
	rm -f $(DESTDIR)$(BINDIR)/dumptxt

	# remove config and dir
	rm -f $(CONFIG_DIR)/config.toml
	rmdir --ignore-fail-on-non-empty $(CONFIG_DIR)

.PHONY: install uninstall
