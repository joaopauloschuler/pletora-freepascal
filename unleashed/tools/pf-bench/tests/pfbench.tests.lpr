{ pfbench.tests — standalone test runner for the pf-bench engine.

  Plain assert-style (no framework), matching this repo's test conventions.
  Exercises every pure half of pfbench.engine against fixtures/synthetic data,
  plus one GUARDED end-to-end that builds and times a tiny fixture with the
  in-tree compiler (fpcu.sh) or a PATH fpc — skipped cleanly when neither is
  found. Never runs the real repo benchmarks.

  Covered (per the pf-bench spec):
    - DISCOVERY finds bench/*.bench.lpr in a temp tree and skips projects with
      no bench/ dir, at all three depths (root/bench, root/*/bench,
      root/*/*/bench).
    - MEDIAN / CHECKSUM extraction.
    - BASELINE CSV round-trips; compare flags an injected slow result past the
      threshold (and passes within it), exits non-zero via AnyRegressed; a new
      benchmark absent from the baseline never counts as a regression.
    - A/B aggregation computes expected speedup ratios from fed-in synthetic
      timings (no compiler); a checksum mismatch marks the row NOT ok and
      fails AbAllOk loudly.
    - GUARDED E2E: build + time a trivial fixture; skip if no compiler found.

  Build & run: ../build-tests.sh }
program pfbenchtests;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, pfbench.engine;

{ ---- assertions -------------------------------------------------------------- }

type
  EAssertFail = class(Exception);

procedure AssertTrue(ACond: Boolean; const AMsg: string);
begin
  if not ACond then
    raise EAssertFail.Create(AMsg);
end;

procedure AssertFalse(ACond: Boolean; const AMsg: string);
begin
  AssertTrue(not ACond, AMsg);
end;

procedure AssertEquals(const AExpected, AActual: string; const AMsg: string);
begin
  if AExpected <> AActual then
    raise EAssertFail.CreateFmt('%s (expected "%s", got "%s")',
      [AMsg, AExpected, AActual]);
end;

procedure AssertEquals(AExpected, AActual: Int64; const AMsg: string);
begin
  if AExpected <> AActual then
    raise EAssertFail.CreateFmt('%s (expected %d, got %d)',
      [AMsg, AExpected, AActual]);
end;

{ ---- fixture helpers ----------------------------------------------------------- }

function MakeTempDir: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) +
    Format('pfbench-test-%d-%d', [GetProcessID, Random(1000000)]);
end;

procedure WriteFileText(const APath, AText: string);
var
  L: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  L := TStringList.Create;
  try
    L.Text := AText;
    L.SaveToFile(APath);
  finally
    L.Free;
  end;
end;

{ Create <root>/<location>/<name>/README.md and (optionally) a bench/<lpr>. }
procedure MakeProject(const ARoot, ALocation, AName: string;
  const ABenchLpr: string = '');
var
  Base, Readme, Lpr: string;
begin
  Base := IncludeTrailingPathDelimiter(ARoot) + ALocation + PathDelim + AName;
  Readme := IncludeTrailingPathDelimiter(Base) + 'README.md';
  WriteFileText(Readme, '# ' + AName + LineEnding + 'body');
  if ABenchLpr <> '' then
  begin
    Lpr := IncludeTrailingPathDelimiter(Base) + 'bench' + PathDelim + ABenchLpr;
    WriteFileText(Lpr, 'program b; begin writeln(''x''); end.');
  end;
end;

function MakeSample(ANanos: QWord; AExit: Integer; ALaunchOk: Boolean): TRunSample;
begin
  Result.Nanos := ANanos;
  Result.ExitCode := AExit;
  Result.LaunchOk := ALaunchOk;
end;

function ContainsName(const ABenches: TBenchmarkArray; const AName: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(ABenches) do
    if ABenches[i].Name = AName then
      Exit(True);
  Result := False;
end;

{ ---- 1. Discovery --------------------------------------------------------------- }

procedure TestDiscoverFindsBenches;
var
  Root: string;
  B: TBenchmarkArray;
begin
  Root := MakeTempDir;
  try
    MakeProject(Root, 'fantastica', 'core', 'fft.bench.lpr');
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'fantastica/core/bench/matrix.bench.lpr',
      'program b; begin end.');
    MakeProject(Root, 'fantastica', 'nobench', ''); { no bench/ dir → skipped }
    MakeProject(Root, 'pletora', 'freepascal', 'compile.bench.lpr');
    { a non-.bench.lpr file must be ignored }
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'fantastica/core/bench/helper.lpr',
      'program h; begin end.');

    B := DiscoverBenchmarks(Root);
    AssertEquals(3, Length(B), 'should find exactly the 3 *.bench.lpr');
    AssertTrue(ContainsName(B, 'core/fft'), 'core/fft present');
    AssertTrue(ContainsName(B, 'core/matrix'), 'core/matrix present');
    AssertTrue(ContainsName(B, 'freepascal/compile'), 'pletora bench present');
    AssertFalse(ContainsName(B, 'nobench/'), 'benchless project skipped');
    { sorted by Name }
    AssertEquals('core/fft', B[0].Name, 'sorted first');
    AssertEquals('freepascal/compile', B[2].Name, 'sorted last');
  finally
    RemoveTree(Root);
  end;
end;

procedure TestDiscoverFlatAndDepth1;
var
  Root: string;
  B: TBenchmarkArray;
begin
  { depth 0: the root itself has a bench/ dir (the fork's unleashed/tests
    layout), plus a depth-1 project beside it }
  Root := MakeTempDir;
  try
    WriteFileText(IncludeTrailingPathDelimiter(Root) + 'bench/flat.bench.lpr',
      'program b; begin end.');
    MakeProject(Root, '.', 'proj1', 'one.bench.lpr');
    B := DiscoverBenchmarks(Root);
    AssertEquals(2, Length(B), 'flat + depth-1 both found');
    AssertTrue(ContainsName(B, ExtractFileName(ExcludeTrailingPathDelimiter(Root)) + '/flat'),
      'root-level bench named after the root dir');
    AssertTrue(ContainsName(B, 'proj1/one'), 'depth-1 project bench present');
  finally
    RemoveTree(Root);
  end;
end;

procedure TestDiscoverSkipsTemplateAndMissing;
var
  Root: string;
  B: TBenchmarkArray;
  Raised: Boolean;
begin
  Root := MakeTempDir;
  try
    MakeProject(Root, 'fantastica', '_template', 'x.bench.lpr'); { skipped }
    B := DiscoverBenchmarks(Root);
    AssertEquals(0, Length(B), '_template excluded');

    Raised := False;
    try
      DiscoverBenchmarks(IncludeTrailingPathDelimiter(Root) + 'does-not-exist');
    except
      on EPfBench do Raised := True;
    end;
    AssertTrue(Raised, 'missing root raises EPfBench');
  finally
    RemoveTree(Root);
  end;
end;

{ ---- 2. Pure stats ---------------------------------------------------------------- }

procedure TestMedianOddEven;
var
  S: TRunSampleArray;
begin
  SetLength(S, 3);
  S[0] := MakeSample(30, 0, True);
  S[1] := MakeSample(10, 0, True);
  S[2] := MakeSample(20, 0, True);
  AssertEquals(20, MedianNanos(S), 'odd median is the middle value');

  SetLength(S, 4);
  S[0] := MakeSample(10, 0, True);
  S[1] := MakeSample(20, 0, True);
  S[2] := MakeSample(40, 0, True);
  S[3] := MakeSample(30, 0, True);
  AssertEquals(25, MedianNanos(S), 'even median is the mean of the two middles');

  { a launch failure is excluded from the median }
  SetLength(S, 3);
  S[0] := MakeSample(100, 0, True);
  S[1] := MakeSample(0, -1, False);
  S[2] := MakeSample(200, 0, True);
  AssertEquals(150, MedianNanos(S), 'launch failure excluded');
end;

procedure TestSummarize;
var
  S: TRunSampleArray;
  St: TBenchStats;
begin
  SetLength(S, 4);
  S[0] := MakeSample(100, 0, True);
  S[1] := MakeSample(200, 0, True);
  S[2] := MakeSample(300, 1, True);   { non-zero exit: failure, still timed }
  S[3] := MakeSample(0, -1, False);   { launch failure: excluded from timing }
  St := Summarize(S);
  AssertEquals(4, St.Count, 'count over all runs');
  AssertEquals(2, St.SuccessCount, 'two exit-0 runs');
  AssertEquals(2, St.FailureCount, 'non-zero exit + launch failure');
  AssertEquals(100, St.MinNanos, 'min over timed runs');
  AssertEquals(300, St.MaxNanos, 'max over timed runs');
  AssertEquals(200, St.MeanNanos, 'mean over timed runs');
end;

procedure TestExtractChecksum;
begin
  AssertEquals('deflate crc=1234', ExtractChecksum('deflate crc=1234' + LineEnding),
    'single trailing newline trimmed');
  AssertEquals('final', ExtractChecksum('noise' + LineEnding + 'final' + LineEnding + LineEnding),
    'last non-empty line wins');
  AssertEquals('', ExtractChecksum('   ' + LineEnding), 'all-blank -> empty');
end;

{ ---- 3. Baseline -------------------------------------------------------------------- }

procedure TestBaselineCsvRoundtrip;
var
  Recs, Back: TBenchRecordArray;
begin
  SetLength(Recs, 2);
  Recs[0].Name := 'core/fft';     Recs[0].MedianNanos := 500000000;
  Recs[0].MeanNanos := 510000000; Recs[0].Checksum := 'fft n=8192 crc=9542C975';
  Recs[1].Name := 'core/matrix';  Recs[1].MedianNanos := 1200000000;
  Recs[1].MeanNanos := 1250000000; Recs[1].Checksum := 'matrix dim=96, crc=3798A60E';

  Back := CsvToBaseline(BaselineToCsv(Recs));
  AssertEquals(2, Length(Back), 'both records round-trip');
  AssertEquals('core/fft', Back[0].Name, 'name preserved');
  AssertEquals(500000000, Back[0].MedianNanos, 'median preserved');
  AssertEquals('matrix dim=96, crc=3798A60E', Back[1].Checksum,
    'checksum with an embedded comma round-trips');
end;

procedure TestBaselineFileRoundtrip;
var
  Dir, Path: string;
  Recs, Back: TBenchRecordArray;
  Raised: Boolean;
begin
  Dir := MakeTempDir;
  try
    ForceDirectories(Dir);
    Path := IncludeTrailingPathDelimiter(Dir) + 'baseline.csv';
    SetLength(Recs, 1);
    Recs[0].Name := 'tests/fft'; Recs[0].MedianNanos := 42;
    Recs[0].MeanNanos := 43; Recs[0].Checksum := 'fft fnv=AB';
    SaveBaseline(Path, Recs);
    Back := LoadBaseline(Path);
    AssertEquals(1, Length(Back), 'file round-trips');
    AssertEquals(42, Back[0].MedianNanos, 'median survives the file');

    Raised := False;
    try
      LoadBaseline(Path + '.missing');
    except
      on EPfBench do Raised := True;
    end;
    AssertTrue(Raised, 'missing baseline file raises EPfBench');
  finally
    RemoveTree(Dir);
  end;
end;

procedure TestCompareRegressionFlaggedAndPassed;
var
  Base, Cur: TBenchRecordArray;
  D: TDeltaArray;
begin
  SetLength(Base, 1);
  Base[0].Name := 'core/fft'; Base[0].MedianNanos := 100;
  SetLength(Cur, 1);
  Cur[0].Name := 'core/fft';

  { +30% slower, threshold 10% -> regression, gate fails }
  Cur[0].MedianNanos := 130;
  D := CompareBaseline(Base, Cur, 10);
  AssertEquals(1, Length(D), 'one delta');
  AssertTrue(D[0].InBaseline, 'found in baseline');
  AssertTrue(D[0].Regressed, '+30% past 10% threshold is a regression');
  AssertTrue(AnyRegressed(D), 'gate reports failure');

  { same +30%, threshold 50% -> within budget, gate passes }
  D := CompareBaseline(Base, Cur, 50);
  AssertFalse(D[0].Regressed, '+30% within 50% threshold is fine');
  AssertFalse(AnyRegressed(D), 'gate passes');

  { faster is never a regression }
  Cur[0].MedianNanos := 70;
  D := CompareBaseline(Base, Cur, 10);
  AssertFalse(D[0].Regressed, 'a speedup is not a regression');
  AssertTrue(D[0].DeltaPct < 0, 'negative delta for a speedup');
end;

procedure TestCompareNewBenchNeverRegresses;
var
  Base, Cur: TBenchRecordArray;
  D: TDeltaArray;
begin
  SetLength(Base, 0);
  SetLength(Cur, 1);
  Cur[0].Name := 'core/newthing'; Cur[0].MedianNanos := 999;
  D := CompareBaseline(Base, Cur, 0);
  AssertFalse(D[0].InBaseline, 'new benchmark not in baseline');
  AssertFalse(D[0].Regressed, 'a new benchmark cannot regress');
  AssertFalse(AnyRegressed(D), 'gate passes when only new benches exist');
end;

{ ---- 4. A/B aggregation ---------------------------------------------------------------- }

function Samples(const AValues: array of QWord): TRunSampleArray;
var
  i: Integer;
begin
  SetLength(Result, Length(AValues));
  for i := 0 to High(AValues) do
    Result[i] := MakeSample(AValues[i], 0, True);
end;

procedure TestAbSpeedupFromSyntheticTimings;
var
  Row: TAbRow;
begin
  { A median 200, B median 100 -> B is 2x faster. }
  Row := BuildAbRow('core/fft', 'same', 'same',
    Samples([210, 190, 200]), Samples([105, 95, 100]));
  AssertEquals(200, Row.MedianA, 'A median');
  AssertEquals(100, Row.MedianB, 'B median');
  AssertTrue(Abs(Row.Speedup - 2.0) < 1e-9, 'speedup = 200/100 = 2.0');
  AssertTrue(Row.ChecksumMatch, 'checksums match');
  AssertTrue(Row.Ok, 'row is ok');
  AssertEquals(190, Row.StatsA.MinNanos, 'Summarize min A');
  AssertEquals(105, Row.StatsB.MaxNanos, 'Summarize max B');
end;

procedure TestAbChecksumMismatchFailsLoudly;
var
  Row: TAbRow;
  Rows: TAbRowArray;
begin
  Row := BuildAbRow('core/deflate', 'crc=AAAA', 'crc=BBBB',
    Samples([100, 100, 100]), Samples([50, 50, 50]));
  AssertFalse(Row.ChecksumMatch, 'checksums differ');
  AssertFalse(Row.Ok, 'a mismatch makes the row NOT ok even though B looks faster');
  AssertTrue(Pos('MISMATCH', Row.Detail) > 0, 'detail names the mismatch');

  SetLength(Rows, 1);
  Rows[0] := Row;
  AssertFalse(AbAllOk(Rows), 'AbAllOk fails on any mismatch');
end;

procedure TestAbRunFailureVoidsRow;
var
  Row: TAbRow;
  A, B: TRunSampleArray;
begin
  A := Samples([100, 100]);
  B := Samples([50, 50]);
  B[0] := MakeSample(50, 1, True); { non-zero exit }
  Row := BuildAbRow('core/x', 'same', 'same', A, B);
  AssertTrue(Row.ChecksumMatch, 'checksums match');
  AssertFalse(Row.Ok, 'a failed run voids the row');
end;

{ ---- 5. Guarded end-to-end ---------------------------------------------------------------- }

{ The in-tree compiler wrapper when this test binary lives in its repo
  (…/unleashed/tools/pf-bench/tests/pfbenchtests → repo root 4 levels up),
  else a PATH fpc, else '' (skip). }
function TestCompiler: string;
var
  D: string;
  i: Integer;
begin
  D := ExtractFileDir(ExpandFileName(ParamStr(0)));
  for i := 1 to 4 do
    D := ExtractFileDir(D);
  Result := D + PathDelim + 'fpcu.sh';
  if FileExists(Result) then
    Exit;
  Result := ResolveCompiler('fpc');
end;

procedure TestEndToEndTrivialFixture;
var
  Fpc, Dir, Lpr, Scratch, Bin, ProbeOut, Cksum: string;
  Samps: TRunSampleArray;
  Stats: TBenchStats;
  ExitCode: Integer;
begin
  Fpc := TestCompiler;
  if Fpc = '' then
  begin
    Writeln('  (skipped: no compiler found)');
    Exit;
  end;
  Dir := MakeTempDir;
  try
    Lpr := IncludeTrailingPathDelimiter(Dir) + 'trivial.bench.lpr';
    { A tiny deterministic workload: a self-timing-free program printing one
      checksum line and exiting 0 — the pf-bench benchmark contract. }
    WriteFileText(Lpr,
      'program trivial;' + LineEnding +
      '{$mode objfpc}{$H+}' + LineEnding +
      'var i: Integer; s: Int64;' + LineEnding +
      'begin' + LineEnding +
      '  s := 0;' + LineEnding +
      '  for i := 1 to 200000 do s := s + i;' + LineEnding +
      '  writeln(''trivial sum='', s);' + LineEnding +
      'end.');
    Scratch := IncludeTrailingPathDelimiter(Dir) + 'scratch';
    Bin := IncludeTrailingPathDelimiter(Dir) + 'trivial';

    BuildBenchmark(Lpr, Fpc, [], Bin, Scratch, False);
    AssertTrue(FileExists(Bin), 'binary produced');

    { checksum probe }
    AssertTrue(RunOnceCapped(Bin, 30, ProbeOut, ExitCode), 'runs and exits 0');
    Cksum := ExtractChecksum(ProbeOut);
    AssertEquals('trivial sum=20000100000', Cksum, 'deterministic checksum');

    { time it }
    Samps := RunSamples(Bin, 2, 1, 30);
    Stats := Summarize(Samps);
    AssertEquals(2, Stats.Count, 'two timed samples');
    AssertEquals(2, Stats.SuccessCount, 'both runs succeeded');
    AssertEquals(0, Stats.FailureCount, 'no failures');
    AssertTrue(MedianNanos(Samps) > 0, 'a real span was measured');
  finally
    RemoveTree(Dir);
  end;
end;

{ ---- harness ------------------------------------------------------------------------------- }

type
  TProc = procedure;

procedure Run(const Name: string; Proc: TProc);
begin
  try
    Proc();
    Writeln('ok   - ', Name);
  except
    on E: Exception do
    begin
      Writeln('FAIL - ', Name, ': ', E.Message);
      Halt(1);
    end;
  end;
end;

begin
  Randomize;
  Run('discover: finds bench/*.bench.lpr, skips benchless + non-.bench', @TestDiscoverFindsBenches);
  Run('discover: flat root/bench and depth-1 layouts', @TestDiscoverFlatAndDepth1);
  Run('discover: skips _template, raises on missing root', @TestDiscoverSkipsTemplateAndMissing);
  Run('median: odd/even, launch failure excluded', @TestMedianOddEven);
  Run('summarize: tallies + timing stats exclude launch failures', @TestSummarize);
  Run('checksum: last non-empty line, trimmed', @TestExtractChecksum);
  Run('baseline: CSV round-trips (incl. embedded comma)', @TestBaselineCsvRoundtrip);
  Run('baseline: file save/load round-trips, missing file raises', @TestBaselineFileRoundtrip);
  Run('compare: regression flagged past threshold, passes within', @TestCompareRegressionFlaggedAndPassed);
  Run('compare: new benchmark never regresses', @TestCompareNewBenchNeverRegresses);
  Run('ab: speedup ratio from synthetic timings', @TestAbSpeedupFromSyntheticTimings);
  Run('ab: checksum mismatch fails loudly', @TestAbChecksumMismatchFailsLoudly);
  Run('ab: a failed run voids the row', @TestAbRunFailureVoidsRow);
  Run('e2e: build + time a trivial fixture (guarded)', @TestEndToEndTrivialFixture);
  Writeln('all tests passed');
end.
