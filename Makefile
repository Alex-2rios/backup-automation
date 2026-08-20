.DEFAULT_GOAL := help
.PHONY: help test lint run verify drill install clean

help:
	@echo "test     run the test suite against temporary directories"
	@echo "lint     run shellcheck over every script"
	@echo "run      run the backup job with the local config"
	@echo "verify   verify every archive"
	@echo "drill    verify and extract the newest archive into a temp directory"
	@echo "install  copy the scripts, config and systemd units into place"
	@echo "clean    remove the local log"

test:
	./tests/test_backup.sh

lint:
	docker run --rm -v "$$PWD:/mnt" koalaman/shellcheck:stable -e SC1090 \
		/mnt/bin/backup.sh /mnt/bin/verify.sh /mnt/bin/restore.sh /mnt/tests/test_backup.sh

run:
	./bin/backup.sh

verify:
	./bin/verify.sh

drill:
	./bin/verify.sh --drill

install:
	sudo install -m 755 bin/backup.sh bin/verify.sh bin/restore.sh /usr/local/bin/
	sudo install -d /etc/backup
	sudo install -m 640 etc/backup.conf.example /etc/backup/backup.conf
	sudo install -m 644 systemd/* /etc/systemd/system/
	sudo systemctl daemon-reload
	@echo "now edit /etc/backup/backup.conf and run: systemctl enable --now backup.timer"

clean:
	rm -f backup.log
