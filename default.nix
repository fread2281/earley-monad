{ mkDerivation, base, containers, criterion, deepseq, ListLike
, parsec, parsers, QuickCheck, stdenv, tasty, tasty-hunit
, tasty-quickcheck
}:
mkDerivation {
  pname = "Earley";
  version = "0.12.1.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    base containers criterion ListLike parsers
  ];
  testHaskellDepends = [
    base QuickCheck tasty tasty-hunit tasty-quickcheck
  ];
  benchmarkHaskellDepends = [
    base containers criterion deepseq ListLike parsec
  ];
  description = "Earley's algorithm extended to context-sensitive grammars";
  license = stdenv.lib.licenses.bsd3;
}
