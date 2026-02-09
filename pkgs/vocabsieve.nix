{
  lib,
  python3,
  fetchFromGitHub,
  python3Packages,
  qtbase,
  wrapQtAppsHook,
  qtmultimedia,
  gst_all_1,
}:

let
  pyqtdarktheme-fork = python3.pkgs.pyqtdarktheme.overrideAttrs (
    final: prev: {
      pname = "pyqtdarktheme-fork";
      version = "2.3.4";

      src = fetchFromGitHub {
        owner = "henriquegemignani";
        inherit (prev.src) repo;
        rev = "v${final.version}";
        hash = "sha256-tvM269xaKK5Emj8h8BZevR+++jD8OUK3tKfPpc3rMlg=";
      };
    }
  );

  pymorphy3 = python3Packages.pymorphy3.overridePythonAttrs (_old: {
    doCheck = false;
  });
in

python3.pkgs.buildPythonApplication rec {
  pname = "vocabsieve";
  version = "0.12.5";
  format = "pyproject";

  src = fetchFromGitHub {
    owner = "FreeLanguageTools";
    repo = pname;
    rev = "v${version}";
    hash = "sha256-agLiHC3CrWeD2/mODdh3xmez0bPFKEovDcsVr0OY244=";
  };

  nativeBuildInputs = [
    wrapQtAppsHook
    gst_all_1.gst-libav
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-vaapi
    gst_all_1.gstreamer
  ];

  dontWrapQtApps = true;

  preFixup = ''
    makeWrapperArgs+=("''${qtWrapperArgs[@]}")
    makeWrapperArgs+=(--prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "$GST_PLUGIN_SYSTEM_PATH_1_0")
  '';

  buildInputs = [
    qtbase
    qtmultimedia
    python3Packages.setuptools
  ];

  propagatedBuildInputs =
    (with python3Packages; [
      markdownify
      mobi
      pymorphy3-dicts-uk
      pymorphy3-dicts-ru
      simplemma
      requests
      readmdict
      slpp
      python-lzo
      packaging
      sentence-splitter
      lxml
      pystardict
      flask
      pysubs2
      bidict
      markdown
      ebooklib
      flask-sqlalchemy
      pyqt5-multimedia
      pyqtgraph
      waitress
      pyqtdarktheme-fork
    ])
    ++ [ pymorphy3 ];

  meta = with lib; {
    description = "Simple sentence mining tool for language learning";
    homepage = "https://github.com/FreeLanguageTools/vocabsieve";
    license = licenses.gpl3;
    maintainers = [ maintainers.inkpot-monkey ];
  };
}
