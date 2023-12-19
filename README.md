# Automatic Nocloud installation

## Requirements
1. Virtual machine with puplic static IP for NoCloud: 2/4/40 SSD with fresh Debian\CentOS\Ubuntu installed. Also the processor(s) must support the SSE2 and AVX instructions.
2. You must add wildcard DNS record *.nocloud.example.tld IN A to IP of this server

***

## Usage
Run script and follow instructions:  
`wget https://raw.githubusercontent.com/suppby/nc_install/main/deployment/ncinstall.sh && bash ncinstall.sh`

### Opennebula
System requirements: https://docs.opennebula.io/stable/intro_release_notes/release_notes/platform_notes.html
