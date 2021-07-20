let
  # https://github.com/NixOS/nixpkgs/pull/124999
  sha256 = "1n1mwh2g15g9fsz5qb7nrwapmc3dlqpd0khc2wfgaaczfq57qcz2";
  # rev = "6ec544db489d5c203204e363e343175fbaa04dac";
in
import (fetchTarball {
  inherit sha256;
  url = "https://github.com/guibou/nixpkgs/archive/71df431b1fa9afc9f79cdf8726c1882a42b7257c.tar.gz";
})
