title: The boot verifies the system before the kernel starts
date: 2026-11-12
release: 0.92.0
picture: docs/screenshots/boot_fails_changed_module.png
kind: Shown
guide: docs/TRUSTED_BOOT.md

A signed system description lists the hash of the kernel and of each file of the boot image. The boot program verifies the signature and each hash before the kernel starts. With one byte of one module changed, the boot stops, and the boot display names the file and both hashes. With a TPM, the boot program measures the description into PCR 11. With Secure Boot on, the firmware starts only the signed boot program. The system of the repository is signed with a test key whose private part is public, and the boot display says so.
