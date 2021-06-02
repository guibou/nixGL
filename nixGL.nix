{ ## Nvidia informations.
  # Version of the system kernel module. Let it to null to enable auto-detection.
  nvidiaVersion ? null,
  # Hash of the Nvidia driver .run file. null is fine, but fixing a value here
  # will be more reproducible and more efficient.
  nvidiaHash ? null,
  # Alternatively, you can pass a path that points to a nvidia version file
  # and let nixGL extract the version from it. That file must be a copy of
  # /proc/driver/nvidia/version. Nix doesn't like zero-sized files (see
  # https://github.com/NixOS/nix/issues/3539 ).
  nvidiaVersionFile ? null,
  # Enable 32 bits driver
  # This is one by default, you can switch it to off if you want to reduce a
  # bit the size of nixGL closure.
  enable32bits ? true,
  writeTextFile, shellcheck, pcre, runCommand, linuxPackages, fetchurl, lib,
  runtimeShell, bumblebee, libglvnd, vulkan-validation-layers, mesa,
  pkgsi686Linux,zlib, libdrm, xorg, wayland, gcc
}:

let
  _nvidiaVersionFile =
    if nvidiaVersionFile != null then
      nvidiaVersionFile
    else
      # HACK: Get the version from /proc. It turns out that /proc is mounted
      # inside of the build sandbox and varies from machine to machine.
      #
      # builtins.readFile is not able to read /proc files. See
      # https://github.com/NixOS/nix/issues/3539.
      runCommand "impure-nvidia-version-file" {
        # To avoid sharing the build result over time or between machine,
        # Add an impure parameter to force the rebuild on each access.
        time = builtins.currentTime;
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      "cp /proc/driver/nvidia/version $out || echo unknown > $out";

  # The nvidia version. Either fixed by the `nvidiaVersion` argument, or
  # auto-detected. Auto-detection is impure.
  _nvidiaVersion =
    if nvidiaVersion != null then
      nvidiaVersion
    else
      # Get if from the nvidiaVersionFile
      let
        data = builtins.readFile _nvidiaVersionFile;
        versionMatch = builtins.match ".*Module  ([0-9.]+)  .*" data;
      in
      if versionMatch != null then
        builtins.head versionMatch
      else
        "unknown";

  addNvidiaVersion = drv: drv.overrideAttrs(oldAttrs: {
    # Auto detected nvidiaVersion (using _nvidiaVersion) causes IFD which breaks nix-env
    # See #72
    name = oldAttrs.name + "-${if nvidiaVersion != null then nvidiaVersion else "unknown"}";
  });

  writeExecutable = { name, text } : writeTextFile {
    inherit name text;

    executable = true;
    destination = "/bin/${name}";


    checkPhase = ''
     ${shellcheck}/bin/shellcheck "$out/bin/${name}"

     # Check that all the files listed in the output binary exists
     for i in $(${pcre}/bin/pcregrep  -o0 '/nix/store/.*?/[^ ":]+' $out/bin/${name})
     do
       ls $i > /dev/null || (echo "File $i, referenced in $out/bin/${name} does not exists."; exit -1)
     done
    '';
  };
in
  rec {
    nvidia = (linuxPackages.nvidia_x11.override {
    }).overrideAttrs(oldAttrs: rec {
      name = "nvidia";
      src = let url = "https://download.nvidia.com/XFree86/Linux-x86_64/${_nvidiaVersion}/NVIDIA-Linux-x86_64-${_nvidiaVersion}.run";
      in if nvidiaHash != null
      then fetchurl {
        inherit url;
        sha256 = nvidiaHash;
      } else
      builtins.fetchurl url;
      useGLVND = true;
    });

    nvidiaLibsOnly = nvidia.override {
      libsOnly = true;
      kernel = null;
    };

  nixGLNvidiaBumblebee = addNvidiaVersion (writeExecutable {
    name = "nixGLNvidiaBumblebee";
    text = ''
      #!${runtimeShell}
      export LD_LIBRARY_PATH=${lib.makeLibraryPath [nvidia]}:$LD_LIBRARY_PATH
      ${bumblebee.override {nvidia_x11 = nvidia; nvidia_x11_i686 = nvidia.lib32;}}/bin/optirun --ldpath ${lib.makeLibraryPath ([libglvnd nvidia] ++ lib.optionals enable32bits [nvidia.lib32 pkgsi686Linux.libglvnd])} "$@"
    '';
  });

  # TODO: 32bit version? Not tested.
  nixNvidiaWrapper = api: addNvidiaVersion (writeExecutable {
    name = "nix${api}Nvidia";
    text = ''
      #!${runtimeShell}
      ${lib.optionalString (api == "Vulkan") ''export VK_LAYER_PATH=${vulkan-validation-layers}/share/vulkan/explicit_layer.d''}

        ${lib.optionalString (api == "Vulkan") ''export VK_ICD_FILENAMES=${nvidiaLibsOnly}/share/vulkan/icd.d/nvidia.json${lib.optionalString enable32bits ":${nvidiaLibsOnly.lib32}/share/vulkan/icd.d/nvidia.json"}:$VK_ICD_FILENAMES''}
        export LD_LIBRARY_PATH=${lib.makeLibraryPath ([
          libglvnd
          nvidiaLibsOnly
        ] ++ lib.optional (api == "Vulkan") vulkan-validation-layers
        ++ lib.optionals enable32bits [nvidiaLibsOnly.lib32 pkgsi686Linux.libglvnd])
      }:''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
        "$@"
      '';
    });

  # TODO: 32bit version? Not tested.
  nixGLNvidia = nixNvidiaWrapper "GL";

  # TODO: 32bit version? Not tested.
  nixVulkanNvidia = nixNvidiaWrapper "Vulkan";

  nixGLIntel = writeExecutable {
    name = "nixGLIntel";
    # add the 32 bits drivers if needed
    text = let
      drivers = [mesa.drivers] ++ lib.optional enable32bits pkgsi686Linux.mesa.drivers;
      glxindirect = runCommand "mesa_glxindirect" {}
        (
          ''mkdir -p $out/lib
            ln -s ${mesa.drivers}/lib/libGLX_mesa.so.0 $out/lib/libGLX_indirect.so.0
          ''
          );
    in ''
      #!${runtimeShell}
      export LIBGL_DRIVERS_PATH=${lib.makeSearchPathOutput "lib" "lib/dri" drivers}
      export LD_LIBRARY_PATH=${
        lib.makeLibraryPath drivers
      }:${glxindirect}/lib:$LD_LIBRARY_PATH
      "$@"
    '';
  };

  nixVulkanIntel = writeExecutable {
    name = "nixVulkanIntel";
    text = let
      # generate a file with the listing of all the icd files
      icd = runCommand "mesa_icd" {}
        (
          # 64 bits icd
          ''ls ${mesa.drivers}/share/vulkan/icd.d/*.json > f
          ''
          #  32 bits ones
          + lib.optionalString enable32bits ''ls ${pkgsi686Linux.mesa.drivers}/share/vulkan/icd.d/*.json >> f
          ''
          # concat everything as a one line string with ":" as seperator
          + ''cat f | xargs | sed "s/ /:/g" > $out''
          );
      in ''
     #!${runtimeShell}
     if [ -n "$LD_LIBRARY_PATH" ]; then
       echo "Warning, nixVulkanIntel overwriting existing LD_LIBRARY_PATH" 1>&2
     fi
     export VK_LAYER_PATH=${vulkan-validation-layers}/share/vulkan/explicit_layer.d
     ICDS=$(cat ${icd})
     export VK_ICD_FILENAMES=$ICDS:$VK_ICD_FILENAMES
     export LD_LIBRARY_PATH=${lib.makeLibraryPath [
       zlib
       libdrm
       xorg.libX11
       xorg.libxcb
       xorg.libxshmfence
       wayland
       gcc.cc
     ]}:$LD_LIBRARY_PATH
     exec "$@"
    '';
  };

  # The output derivation contains nixGL which point either to
  # nixGLNvidia or nixGLIntel using an heuristic.
  nixGLDefault = nixGL: runCommand "nixGLCommon" {} ''
    mkdir -p "$out/bin"
    # The detection of the version is done here instead of outside in nix
    # because this way it is lazy and the weird evaluation of '/proc/...' does
    # not break nix evaluation. See #72.
    if [ "${nvidiaVersion}" == "unknown" ]
    then
      cp ${nixGLIntel}/bin/* "$out/bin/nixGL";
    else
      # star because nixGLNvidia... have version prefixed name
      cp ${nixGLNvidia}/bin/* "$out/bin/nixGL";
    fi
  '';
}
