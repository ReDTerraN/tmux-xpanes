# How to maintain test cases

1. Please make sure that GNU sed, [pict](https://github.com/microsoft/pict) and [shunit2](https://github.com/kward/shunit2.git) and are installed.

Example for pict: 
```bash
$ git clone https://github.com/Microsoft/pict.git
$ cd pict/
#### Install Clang and libc++ on Ubuntu if necessary
$ sudo apt-get install clang libc++-dev
$ make
$ sudo install -m 0755 pict /usr/local/bin/pict
```

Example for shunit2: 
```bash
$ git clone https://github.com/kward/shunit2.git
$ cd shunit2/
$ cp * /path_to_xpanes_project/test/shunit2/
```

3. Edit `config.pict` to add/remove/modify software versions.

4. Run `bash ./update_yaml.sh`
