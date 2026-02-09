{
  lib,
  python3Packages,
}:

python3Packages.buildPythonPackage {
  pname = "finance-tools";
  version = "0.1.12";
  pyproject = true;

  src = lib.cleanSourceWith {
    src = ./.;
    filter = name: _type: baseNameOf name != "result" && baseNameOf name != ".git";
  };

  nativeBuildInputs = [
    python3Packages.setuptools
  ];

  propagatedBuildInputs = with python3Packages; [
    beangulp
    beancount
    fava
    python-dateutil
    openai
    scikit-learn
    litellm
  ];

  # Allow no tests for now as we have a custom test script we might migrate later
  doCheck = false;

  meta = with lib; {
    description = "Personal finance ingestion tools";
    license = licenses.mit; # Assuming MIT, adjust if needed
    maintainers = [ ];
  };
}
