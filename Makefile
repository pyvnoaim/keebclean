keebclean: main.swift
	swiftc -O main.swift -o keebclean

# demo mode doubles as the self-check: exits nonzero if the layout or unlock logic breaks
test: keebclean
	./keebclean --demo --mute < /dev/null > /dev/null
	# a typo must never lock the keyboard
	./keebclean --tset > /dev/null; test $$? -eq 2

install: keebclean
	./keebclean --install

uninstall: keebclean
	./keebclean --uninstall

clean:
	rm -f keebclean

.PHONY: test install uninstall clean
