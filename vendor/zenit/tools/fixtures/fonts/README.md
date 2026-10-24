# Windows font probe fixtures

Unmodified Lora regular and bold italic static TTF files from The Lora Project Authors.
Distributed under the SIL Open Font License 1.1; see `Lora-OFL.txt` for the
copyright, reserved font name and full terms.

The Windows font smoke executable embeds these files, writes them to its own
random TEMP directory using Unicode filenames, and removes that directory on
exit. They exercise private file collections without OS font installation.
