# Maps of system pkg references from cabal file to nixpkgs pkgs.
# library name (from `extra-libraries` field of `.cabal` file) -> nixpkgs package(s) mapping.
# This mapping is used to construct the `libs` component attribute.
# See ../docs/tutorials/pkg-map.md
pkgs:

with pkgs;

let
  # On windows systems we need these to be propagatedBuildInputs so that the DLLs will be found.
  gcclibs = if pkgs.stdenv.hostPlatform.isWindows then [
    # Find the versions of mcfgthreads used by stdenv.cc
    (pkgs.threadsCrossFor or (_x: { package = pkgs.windows.mcfgthreads; }) pkgs.stdenv.cc.version).package
    # If we just use `pkgs.buildPackages.gcc.cc` here it breaks the `th-dlls` test. TODO figure out why exactly.
    (pkgs.buildPackages.runCommand "gcc-only" { nativeBuildInputs = [ (pkgs.buildPackages.lndir or pkgs.buildPackages.xorg.lndir) ]; } ''
      mkdir $out
      lndir ${pkgs.buildPackages.gcc.cc} $out
    '')
  ] else [];
  # In newer versions of nixpkgs `pg_config` has been moved to its own derivation.
  # Haskell libs that depend on the `pq` library (like `postgresql-libpq`)
  # are likely to require `pg_config` to be in the `PATH` as well.
  postgresqlLibs = [ postgresql ] ++ lib.optional (postgresql ? pg_config) postgresql.pg_config;
in
# -- linux
{ crypto = [ openssl ];
  # libc, librt, libdl — provided implicitly by the toolchain.
  # GHC 9.14's rts.cabal lists these as extra-libraries on Linux.
  c = [];
  rt = [];
  dl = [];
  "c++" = [ libcxx ];
  # at some point this happened:
  #
  #    error: 'libcxxabi' was merged into 'libcxx'
  #
  "c++abi" = if (__tryEval libcxxabi).success then [ libcxxabi ] else [ libcxx ];
  system-cxx-std-lib = [];
  "stdc++" = gcclibs;
  "stdc++-6" = gcclibs;
  gcc_s_seh-1 = gcclibs;
  gcc_s = gcclibs;
  gcc = gcclibs;
  ssl = [ openssl ];
  z = [ zlib ];
  m = []; # Included with ghc
  pcap = [ libpcap ];
  pthread = null; # available by default
  GL = [ libGL ];
  GLEW = [ glew ];
  GLU = [ libGLU ];
  alut = [ freealut ];
  X11 = [ (pkgs.libx11 or xorg.libX11) ];
  Xrandr = [ (pkgs.libxrandr or xorg.libXrandr) ];
  Xrender = [ (pkgs.libxrender or xorg.libXrender) ];
  Xss = [ (pkgs.libxscrnsaver or xorg.libXScrnSaver) ];
  Xext = [ (pkgs.libxext or xorg.libXext) ];
  Xi = [ (pkgs.libxi or xorg.libXi) ];
  Xxf86vm = [ (pkgs.libxxf86vm or xorg.libXxf86vm) ];
  Xcursor = [ (pkgs.libxcursor or xorg.libXcursor) ];
  Xinerama = [ (pkgs.libxinerama or xorg.libXinerama) ];
  mysqlclient = [ mysql ];
  Imlib2 = [ imlib2 ];
  asound = [ alsaLib ];
  ffi = null;
  bz2 = [ bzip2 ];
  util = [ utillinux ];
  magic = [ file ];
  pgcommon = postgresqlLibs;
  pgport = postgresqlLibs;
  pq = postgresqlLibs;
  libpq = postgresqlLibs;
  iconv = [ libiconv ];
  lapack = [ liblapack ];
  boost_atomic = [ boost ];
  boost_chrono = [ boost ];
  boost_container = [ boost ];
  boost_context = [ boost ];
  boost_contract = [ boost ];
  boost_coroutine = [ boost ];
  boost_date_time = [ boost ];
  boost_fiber = [ boost ];
  boost_filesystem = [ boost ];
  boost_graph = [ boost ];
  boost_iostreams = [ boost ];
  boost_locale = [ boost ];
  boost_log_setup = [ boost ];
  boost_log = [ boost ];
  boost_math_c99f = [ boost ];
  boost_math_c99l = [ boost ];
  boost_math_c99 = [ boost ];
  boost_math_tr1f = [ boost ];
  boost_math_tr1l = [ boost ];
  boost_math_tr1 = [ boost ];
  boost_prg_exec_monitor = [ boost ];
  boost_program_options = [ boost ];
  boost_random = [ boost ];
  boost_regex = [ boost ];
  boost_serialization = [ boost ];
  boost_signals = [ boost ];
  boost_stacktrace_addr2line = [ boost ];
  boost_stacktrace_basic = [ boost ];
  boost_stacktrace_noop = [ boost ];
  boost_system = [ boost ];
  boost_thread = [ boost ];
  boost_timer = [ boost ];
  boost_type_erasure = [ boost ];
  boost_unit_test_framework = [ boost ];
  boost_wave = [ boost ];
  boost_wserialization = [ boost ];
  tensorflow = [ libtensorflow ];
  # odbc package requires unixODBC packages to be installed in order to successfully
  # compile C sources (https://github.com/fpco/odbc/blob/master/cbits/odbc.c)
  odbc = [ (pkgs.unixodbc or unixODBC) ];
  opencv = [ opencv3 ];
  phonenumber = [ libphonenumber ];
  icuuc = [ icu ];
  icui18n = [ icu ];
  icu-i18n = [ icu ];
  icudata = [ icu ];
  vulkan = [ vulkan-loader ];
  sodium = [ libsodium ];
  gfortran = [ gfortran.cc.lib ];
  ssh2 = [ libssh2 ];
  gpiod = [ libgpiod ];
  png = [ libpng ];
  jpeg = [ libjpeg ];
  freenect_sync = [ freenect ];
  FLAC = [ flac ];
  mp3lame = [ lame ];
  tag_c = [ taglib ];
  jwt = [ libjwt ];
  GeoIP = [ geoip ];
  pulse-simple = [ libpulseaudio ];
  oath = [ liboauth ];
  sqlite3 = [ sqlite ];
}
# -- windows
// { advapi32 = null; gdi32 = null; imm32 = null; msimg32 = null;
     shell32 = null; shfolder = null; shlwapi = null; user32 = null;
     ole32 = null; rpcrt4 = null;
     winmm = null; userenv = null;
     kernel32 = null; ws2_32 = null;
     # GHC 9.14's rts.cabal / ghc-internal.cabal extra-libraries on
     # Windows; all provided implicitly by the mingw toolchain.
     wsock32 = null; dbghelp = null; psapi = null;
     ntdll = null; ucrt = null;
     opengl32 = null; glu32 = null;
     # this should be bundled with gcc.
     # if it's not we have more severe
     # issues anyway.
     ssl32 = null; eay32 = [ openssl ];
     iphlpapi = null; # IP Help API
     msvcrt = null; # this is the libc
     # MinGW import-library names are lowercase; retain the legacy alias.
     crypt32 = null;
     Crypt32 = null;
     mswsock = null;
     bcrypt = null;
     dnsapi = null;
   }
# -- mingw32
// { mingwex = null;
     # GHC 9.14's ghc-internal lists mingw32 in extra-libraries on Windows;
     # provided implicitly by the mingw toolchain.
     mingw32 = null;
}
# -- os x
# TODO remove once planner code is updated not to output frameworks
# (we can only do that once we no longer support old nixpkgs where
# framework derivations are needed)
//
(
let
  # If this file exists then the frameworks are all probably stubbed out
  # and we can avoid warnings by ignoring them.
  hasMkStubs = builtins.pathExists (pkgs.path + "/pkgs/os-specific/darwin/apple-sdk/mk-stub.nix");
  frameworkNames =
        [
          "AGL"
          "AVFCapture"
          "AVFCore"
          "AVFoundation"
          "AVKit"
          "Accelerate"
          "Accessibility"
          "Accounts"
          "AdServices"
          "AdSupport"
          "AddressBook"
          "AddressBookCore"
          "AppKit"
          "AppTrackingTransparency"
          "Apple80211"
          "AppleScriptKit"
          "AppleScriptObjC"
          "ApplicationServices"
          "AudioToolbox"
          "AudioToolboxCore"
          "AudioUnit"
          "AudioVideoBridging"
          "AuthenticationServices"
          "AutomaticAssessmentConfiguration"
          "Automator"
          "BackgroundTasks"
          "BusinessChat"
          "CFNetwork"
          "CalendarStore"
          "CallKit"
          "Carbon"
          "ClassKit"
          "CloudKit"
          "Cocoa"
          "Collaboration"
          "ColorSync"
          "Combine"
          "Contacts"
          "ContactsPersistence"
          "ContactsUI"
          "CoreAudio"
          "CoreAudioKit"
          "CoreAudioTypes"
          "CoreBluetooth"
          "CoreData"
          "CoreDisplay"
          "CoreFoundation"
          "CoreGraphics"
          "CoreHaptics"
          "CoreImage"
          "CoreLocation"
          "CoreMIDI"
          "CoreMIDIServer"
          "CoreML"
          "CoreMedia"
          "CoreMediaIO"
          "CoreMotion"
          "CoreServices"
          "CoreSpotlight"
          "CoreSymbolication"
          "CoreTelephony"
          "CoreText"
          "CoreVideo"
          "CoreWLAN"
          "CryptoKit"
          "CryptoTokenKit"
          "DVDPlayback"
          "DebugSymbols"
          "DeveloperToolsSupport"
          "DeviceCheck"
          "DirectoryService"
          "DiscRecording"
          "DiscRecordingUI"
          "DiskArbitration"
          "DisplayServices"
          "DriverKit"
          "EventKit"
          "ExceptionHandling"
          "ExecutionPolicy"
          "ExternalAccessory"
          "FWAUserLib"
          "FileProvider"
          "FileProviderUI"
          "FinderSync"
          "ForceFeedback"
          "Foundation"
          "GLKit"
          "GLUT"
          "GSS"
          "GameCenterFoundation"
          "GameCenterUI"
          "GameCenterUICore"
          "GameController"
          "GameKit"
          "GameplayKit"
          "HIDDriverKit"
          "Hypervisor"
          "ICADevices"
          "IMServicePlugIn"
          "IOBluetooth"
          "IOBluetoothUI"
          "IOKit"
          "IOSurface"
          "IOUSBHost"
          "IdentityLookup"
          "ImageCaptureCore"
          "ImageIO"
          "InputMethodKit"
          "InstallerPlugins"
          "InstantMessage"
          "Intents"
          "JavaNativeFoundation"
          "JavaRuntimeSupport"
          "JavaScriptCore"
          "JavaVM"
          "Kerberos"
          "Kernel"
          "KernelManagement"
          "LDAP"
          "LatentSemanticMapping"
          "LinkPresentation"
          "LocalAuthentication"
          "MLCompute"
          "MapKit"
          "MediaAccessibility"
          "MediaLibrary"
          "MediaPlayer"
          "MediaRemote"
          "MediaToolbox"
          "Message"
          "Metal"
          "MetalKit"
          "MetalPerformanceShaders"
          "MetalPerformanceShadersGraph"
          "MetricKit"
          "ModelIO"
          "MultipeerConnectivity"
          "MultitouchSupport"
          "NaturalLanguage"
          "NearbyInteraction"
          "NetFS"
          "Network"
          "NetworkExtension"
          "NetworkingDriverKit"
          "NotificationCenter"
          "OSAKit"
          "OSLog"
          "OpenAL"
          "OpenCL"
          "OpenDirectory"
          "OpenGL"
          "PCIDriverKit"
          "PCSC"
          "PDFKit"
          "ParavirtualizedGraphics"
          "PassKit"
          "PassKitCore"
          "PencilKit"
          "Photos"
          "PhotosUI"
          "PreferencePanes"
          "PushKit"
          "Python"
          "QTKit"
          "Quartz"
          "QuartzCore"
          "QuickLook"
          "QuickLookThumbnailing"
          "QuickTime"
          "RealityKit"
          "ReplayKit"
          "Ruby"
          "SafariServices"
          "SceneKit"
          "ScreenSaver"
          "ScreenTime"
          "ScriptingBridge"
          "Security"
          "SecurityFoundation"
          "SecurityInterface"
          "SensorKit"
          "ServiceManagement"
          "SignpostMetrics"
          "SkyLight"
          "Social"
          "SoundAnalysis"
          "Speech"
          "SpriteKit"
          "StoreKit"
          "SwiftUI"
          "SyncServices"
          "System"
          "SystemConfiguration"
          "SystemExtensions"
          "TWAIN"
          "Tcl"
          "Tk"
          "UIFoundation"
          "URLFormatting"
          "USBDriverKit"
          "UniformTypeIdentifiers"
          "UserNotifications"
          "UserNotificationsUI"
          "VideoDecodeAcceleration"
          "VideoSubscriberAccount"
          "VideoToolbox"
          "Virtualization"
          "Vision"
          "WebKit"
          "WidgetKit"
          "iTunesLibrary"
          "vmnet"
        ];

in
  lib.optionalAttrs stdenv.hostPlatform.isDarwin
    (lib.genAttrs frameworkNames
      (n:
        # Check to see if this is an old nixpkgs where we need framework derivations
        if !hasMkStubs
          # In future versions of `nixpkgs` these will be removed
          # so make sure they are there.
          && darwin ? apple_sdk
          && (builtins.tryEval (darwin.apple_sdk ? frameworks)).success
          && darwin.apple_sdk ? frameworks
          && darwin.apple_sdk.frameworks ? ${n}
          && !(darwin.apple_sdk.frameworks.${n}.passthru.isDarwinCompatStub or false)
        then darwin.apple_sdk.frameworks.${n}
        else null))
)
