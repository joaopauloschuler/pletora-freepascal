{ pfbench.engine — the reusable core of the pf-bench benchmark harness.

  pf-bench discovers `bench/*.bench.lpr` programs, builds each with a selectable
  compiler + flag set, runs them with warm-up and repeated timed runs, and
  compares results. This unit holds every piece that can be tested WITHOUT
  invoking a compiler, plus the thin build/run helpers the CLI drives.

  Ported into this repository from the fantastica monorepo's pf-bench; the
  fantastica core/timeit dependencies were replaced with their FCL/RTL
  equivalents (TProcess, csvdocument, clock_gettime, Math) and the Result-typed
  error handling with exceptions (EPfBench). The statistics that used to live in
  timeit.core (TRunSample, TBenchStats, Summarize) are inlined here.

  Every benchmark prints a single deterministic checksum line, so two builds can
  be asserted to produce the SAME answer before their speed is compared — a
  miscompiling optimizer pass must FAIL the run, not win it.

  The layers, each independently unit-testable:

    1. DISCOVERY — DiscoverBenchmarks(root) collects every bench/*.bench.lpr
       found at <root>/bench, <root>/<proj>/bench and <root>/<loc>/<proj>/bench
       (so it covers both a flat fixture dir and a monorepo layout). Projects
       without a bench/ dir are skipped.

    2. PURE STATS — Summarize, MedianNanos, ExtractChecksum. No spawning.

    3. BASELINE — TBenchRecord round-trips through CSV (csvdocument);
       CompareBaseline folds a baseline + a current run into per-benchmark
       deltas and flags regressions past a threshold. Pure data.

    4. A/B — BuildAbRow folds two sample arrays (compiler A vs compiler B) plus
       their checksums into a speedup row; a checksum mismatch marks the row
       NOT ok. Pure data.

    5. BUILD / RUN — BuildBenchmark compiles one .bench.lpr with a chosen
       compiler and flag list; RunOnceCapped / RunSamples / RunInterleaved run
       a built binary UNDER A MEMORY + TIME CAP (ulimit -v + timeout, via
       bash), timing each scored run with the monotonic clock. RunInterleaved
       alternates A and B run-by-run (ABAB…) to cancel thermal / frequency
       drift. }
unit pfbench.engine;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  EPfBench = class(Exception);

  { One timed execution: its wall-clock span in nanoseconds and the exit code
    the command returned (0 = success). LaunchOk is False when the command
    could not be launched at all; such a run is still recorded so the caller
    sees it, with Nanos = 0. }
  TRunSample = record
    Nanos: QWord;
    ExitCode: Integer;
    LaunchOk: Boolean;
  end;
  TRunSampleArray = array of TRunSample;

  { Folded statistics over a set of timed runs. All spans are nanoseconds.
    Stddev is the POPULATION standard deviation (divides by N, not N-1). }
  TBenchStats = record
    Count: Integer;        { number of samples }
    MinNanos: QWord;
    MaxNanos: QWord;
    MeanNanos: QWord;      { rounded to the nearest nanosecond }
    StddevNanos: QWord;    { population stddev, rounded to nearest nanosecond }
    SuccessCount: Integer; { runs that exited 0 }
    FailureCount: Integer; { runs that exited non-zero (or failed to launch) }
  end;

  { One discovered benchmark: a bench/*.bench.lpr in a project. }
  TBenchmark = record
    Project: string;     { folder name }
    Location: string;    { parent location name ('' at depth 0/1) }
    ProjectDir: string;  { absolute project directory }
    LprPath: string;     { absolute path to the bench/*.bench.lpr }
    Name: string;        { '<project>/<file-base>' — the benchmark's report id }
  end;
  TBenchmarkArray = array of TBenchmark;

const
  { Per-run resource caps. }
  MEM_CAP_KB = 3000000;        { ulimit -v, in KB (~3 GB address space) }
  DEFAULT_TIME_CAP_S = 120;    { timeout, in seconds }

{ ---- 1. Discovery ---------------------------------------------------------- }

{ Collect every bench/*.bench.lpr under ARoot, SORTED by Name. Three layouts
  are scanned: ARoot/bench (ARoot itself is the project), ARoot/<proj>/bench,
  and ARoot/<loc>/<proj>/bench. _template and hidden folders are skipped.
  Raises EPfBench when the root is missing. }
function DiscoverBenchmarks(const ARoot: string): TBenchmarkArray;

{ ---- 2. Pure stats ---------------------------------------------------------- }

{ Fold an array of run samples into summary statistics. An empty array yields
  an all-zero TBenchStats. A run that failed to launch counts as a failure and
  its (zero) span is excluded from min/mean/max so a launch failure does not
  masquerade as an instant run. }
function Summarize(const ASamples: TRunSampleArray): TBenchStats;

{ Median wall-clock span (ns) over the TIMED samples (launch failures
  excluded). Even count → mean of the two middle values. 0 when nothing
  timed. Baselines record medians. }
function MedianNanos(const ASamples: TRunSampleArray): QWord;

{ A benchmark prints a single deterministic checksum line. Extract it as the
  last non-empty line of ASTDOUT, trimmed — tolerant of a trailing newline or
  an incidental blank line. }
function ExtractChecksum(const AStdout: string): string;

{ ---- 3. Baseline records + compare ----------------------------------------- }

type
  { A recorded baseline point for one benchmark. }
  TBenchRecord = record
    Name: string;
    MedianNanos: QWord;
    MeanNanos: QWord;
    Checksum: string;
  end;
  TBenchRecordArray = array of TBenchRecord;

  { One benchmark's delta vs a baseline. }
  TDelta = record
    Name: string;
    InBaseline: Boolean;    { False = benchmark is new (absent from baseline) }
    BaselineNanos: QWord;
    CurrentNanos: QWord;
    DeltaPct: Double;       { (current - baseline) / baseline * 100; +ve = slower }
    Regressed: Boolean;     { InBaseline and DeltaPct > threshold }
  end;
  TDeltaArray = array of TDelta;

{ Serialize baseline records to CSV text (header: name,median_ns,mean_ns,
  checksum) via csvdocument, so it round-trips losslessly. }
function BaselineToCsv(const ARecs: TBenchRecordArray): string;

{ Parse CSV text (as written by BaselineToCsv) back into records. Rows with an
  empty name are skipped. }
function CsvToBaseline(const AText: string): TBenchRecordArray;

{ Write / read a baseline CSV file. Raise EPfBench on IO errors. }
procedure SaveBaseline(const APath: string; const ARecs: TBenchRecordArray);
function LoadBaseline(const APath: string): TBenchRecordArray;

{ Fold a baseline and a current run into per-benchmark deltas. One TDelta per
  CURRENT benchmark (order preserved). A benchmark absent from the baseline is
  reported with InBaseline=False and never counts as a regression. A benchmark
  gets Regressed=True when it is slower than baseline by MORE than
  AThresholdPct percent. }
function CompareBaseline(const ABaseline, ACurrent: TBenchRecordArray;
  AThresholdPct: Double): TDeltaArray;

{ True iff any delta regressed — the CI gate. }
function AnyRegressed(const ADeltas: TDeltaArray): Boolean;

{ ---- 4. A/B aggregation ---------------------------------------------------- }

type
  { One benchmark's A-vs-B outcome. }
  TAbRow = record
    Name: string;
    ChecksumA, ChecksumB: string;
    ChecksumMatch: Boolean;      { A and B produced the SAME answer }
    MedianA, MedianB: QWord;
    StatsA, StatsB: TBenchStats;
    Speedup: Double;             { MedianA / MedianB; >1 means B is faster }
    Ok: Boolean;                 { checksums match AND no failed runs }
    Detail: string;              { human note (e.g. why it is not Ok) }
  end;
  TAbRowArray = array of TAbRow;

{ Fold two sample arrays + their checksums into an A/B row. Speedup is
  MedianA/MedianB (0 when MedianB is 0). Ok requires the checksums to match
  and both sides to have zero failed runs — a mismatch or a non-zero exit
  means the speed number must NOT be trusted. }
function BuildAbRow(const AName, AChecksumA, AChecksumB: string;
  const ASamplesA, ASamplesB: TRunSampleArray): TAbRow;

{ True iff every A/B row is Ok (all checksums matched, no failed runs). }
function AbAllOk(const ARows: TAbRowArray): Boolean;

{ ---- 5. Build / run -------------------------------------------------------- }

{ Compile ALprPath with ACompiler and AFlags into AOutBin, using AScratchDir
  for throwaway .ppu/.o output. AFlags is passed verbatim BEFORE the source
  (the caller composes -Fu / -O… etc.); -FU<scratch>, -o<out> and the source
  path are appended by this function. Raises EPfBench (with the compiler's
  message) unless the compiler exits 0 and produced the binary. }
procedure BuildBenchmark(const ALprPath, ACompiler: string;
  const AFlags: array of string; const AOutBin, AScratchDir: string;
  AVerbose: Boolean);

{ Run ABin ONCE under `ulimit -v <cap> && timeout <s> <bin>` (via bash),
  capturing its stdout and exit code. Returns True on exit 0. A launch failure
  yields False, empty stdout, exit -1. }
function RunOnceCapped(const ABin: string; ATimeoutS: Integer;
  out AStdout: string; out AExitCode: Integer): Boolean;

{ Run ABin ARuns times under the cap (after AWarmup discarded warm-ups),
  timing each scored run with the monotonic clock. }
function RunSamples(const ABin: string; ARuns, AWarmup, ATimeoutS: Integer):
  TRunSampleArray;

{ Interleave the timed runs of two binaries ABAB… to cancel thermal /
  frequency drift: after AWarmup discarded warm-ups of each, run A then B on
  every scored iteration, filling ASamplesA and ASamplesB. }
procedure RunInterleaved(const ABinA, ABinB: string;
  ARuns, AWarmup, ATimeoutS: Integer;
  out ASamplesA, ASamplesB: TRunSampleArray);

{ Resolve an executable name on PATH ('' when not found). An absolute/relative
  path that exists is returned as-is, so a fork compiler path (or a wrapper
  script like fpcu.sh) passes through. }
function ResolveCompiler(const ANameOrPath: string): string;

{ Remove a directory tree (used to clean throwaway scratch dirs). }
procedure RemoveTree(const ADir: string);

implementation

uses
  Math, Unix, Linux, UnixType, process, csvdocument;

{ ---- monotonic clock ------------------------------------------------------- }

function NowNanos: QWord;
var
  ts: timespec;
begin
  if clock_gettime(CLOCK_MONOTONIC, @ts) <> 0 then
    raise EPfBench.Create('clock_gettime(CLOCK_MONOTONIC) failed');
  Result := QWord(ts.tv_sec) * 1000000000 + QWord(ts.tv_nsec);
end;

{ ---- process helper -------------------------------------------------------- }

type
  TProcOutcome = record
    Launched: Boolean;
    ExitCode: Integer;
    Stdout: string;
    Stderr: string;
  end;

{ Run AExe with AArgs (each a separate argv entry — never a shell string) in
  ACwd, draining stdout/stderr as it runs (no pipe deadlock), and wait for
  exit. Launched=False when the executable could not be started. }
function RunProcess(const AExe: string; const AArgs: array of string;
  const ACwd: string): TProcOutcome;
const
  BUF_SIZE = 16384;
var
  P: TProcess;
  OutS, ErrS: TStringStream;
  Buf: array[0..BUF_SIZE - 1] of Byte;
  n: LongInt;
  i: Integer;
  Drained: Boolean;
begin
  Result.Launched := False;
  Result.ExitCode := -1;
  Result.Stdout := '';
  Result.Stderr := '';
  P := TProcess.Create(nil);
  OutS := TStringStream.Create('');
  ErrS := TStringStream.Create('');
  try
    P.Executable := AExe;
    for i := 0 to High(AArgs) do
      P.Parameters.Add(AArgs[i]);
    if ACwd <> '' then
      P.CurrentDirectory := ACwd;
    P.Options := [poUsePipes];
    try
      P.Execute;
    except
      on E: Exception do
        Exit;
    end;
    Result.Launched := True;
    repeat
      Drained := False;
      if P.Output.NumBytesAvailable > 0 then
      begin
        n := P.Output.Read(Buf, BUF_SIZE);
        if n > 0 then begin OutS.Write(Buf, n); Drained := True; end;
      end;
      if P.Stderr.NumBytesAvailable > 0 then
      begin
        n := P.Stderr.Read(Buf, BUF_SIZE);
        if n > 0 then begin ErrS.Write(Buf, n); Drained := True; end;
      end;
      if not Drained then
      begin
        if not P.Running then
          Break;
        Sleep(1);
      end;
    until False;
    P.WaitOnExit;
    { ExitCode, not ExitStatus: on Unix the latter is the raw waitpid status
      (exit 1 reads as 256). }
    Result.ExitCode := P.ExitCode;
    Result.Stdout := OutS.DataString;
    Result.Stderr := ErrS.DataString;
  finally
    ErrS.Free;
    OutS.Free;
    P.Free;
  end;
end;

{ The last ACount non-empty lines of AText, joined with ' | ' — compact enough
  for a one-line error message. }
function LastLines(const AText: string; ACount: Integer): string;
var
  Lines: TStringList;
  i, Taken: Integer;
  L: string;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Taken := 0;
    for i := Lines.Count - 1 downto 0 do
    begin
      L := Trim(Lines[i]);
      if L = '' then
        Continue;
      if Result = '' then
        Result := L
      else
        Result := L + ' | ' + Result;
      Inc(Taken);
      if Taken >= ACount then
        Break;
    end;
  finally
    Lines.Free;
  end;
end;

{ ---- 1. Discovery ---------------------------------------------------------- }

const
  BENCH_SUFFIX = '.bench.lpr';

procedure CollectBenchmarks(const AProjectDir, AProjectName, ALocationName: string;
  var AList: TBenchmarkArray);
var
  BenchDir: string;
  Info: TSearchRec;
  B: TBenchmark;
begin
  BenchDir := IncludeTrailingPathDelimiter(AProjectDir) + 'bench';
  if not DirectoryExists(BenchDir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(BenchDir) + '*' + BENCH_SUFFIX,
    faAnyFile, Info) <> 0 then
    Exit;
  try
    repeat
      if (Info.Attr and faDirectory) <> 0 then
        Continue;
      B.Project := AProjectName;
      B.Location := ALocationName;
      B.ProjectDir := ExcludeTrailingPathDelimiter(AProjectDir);
      B.LprPath := IncludeTrailingPathDelimiter(BenchDir) + Info.Name;
      B.Name := AProjectName + '/' +
        Copy(Info.Name, 1, Length(Info.Name) - Length(BENCH_SUFFIX));
      SetLength(AList, Length(AList) + 1);
      AList[High(AList)] := B;
    until FindNext(Info) <> 0;
  finally
    FindClose(Info);
  end;
end;

function SkippableFolder(const AName: string): Boolean;
begin
  Result := (AName = '.') or (AName = '..') or (AName = '_template') or
    ((Length(AName) > 0) and (AName[1] = '.'));
end;

procedure ScanLocation(const ALocationDir, ALocationName: string;
  var AList: TBenchmarkArray);
var
  Info: TSearchRec;
  Folder: string;
begin
  if not DirectoryExists(ALocationDir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ALocationDir) + '*', faDirectory, Info) <> 0 then
    Exit;
  try
    repeat
      if (Info.Attr and faDirectory) = 0 then
        Continue;
      if SkippableFolder(Info.Name) then
        Continue;
      Folder := IncludeTrailingPathDelimiter(ALocationDir) + Info.Name;
      CollectBenchmarks(Folder, Info.Name, ALocationName, AList);
    until FindNext(Info) <> 0;
  finally
    FindClose(Info);
  end;
end;

procedure SortBenchmarks(var AList: TBenchmarkArray);
var
  i, j: Integer;
  Tmp: TBenchmark;
begin
  for i := 1 to High(AList) do
  begin
    Tmp := AList[i];
    j := i - 1;
    while (j >= 0) and (AList[j].Name > Tmp.Name) do
    begin
      AList[j + 1] := AList[j];
      Dec(j);
    end;
    AList[j + 1] := Tmp;
  end;
end;

function DiscoverBenchmarks(const ARoot: string): TBenchmarkArray;
var
  Root, Sub: string;
  List: TBenchmarkArray;
  Info: TSearchRec;
begin
  Root := ExcludeTrailingPathDelimiter(ExpandFileName(ARoot));
  if not DirectoryExists(Root) then
    raise EPfBench.CreateFmt('root path does not exist: %s', [ARoot]);
  List := nil;
  { depth 0: the root itself is a project with a bench/ dir }
  CollectBenchmarks(Root, ExtractFileName(Root), '', List);
  { depth 1: <root>/<proj>/bench }
  ScanLocation(Root, '', List);
  { depth 2: <root>/<loc>/<proj>/bench (monorepo layout) }
  if FindFirst(IncludeTrailingPathDelimiter(Root) + '*', faDirectory, Info) = 0 then
  begin
    try
      repeat
        if (Info.Attr and faDirectory) = 0 then
          Continue;
        if SkippableFolder(Info.Name) then
          Continue;
        Sub := IncludeTrailingPathDelimiter(Root) + Info.Name;
        ScanLocation(Sub, Info.Name, List);
      until FindNext(Info) <> 0;
    finally
      FindClose(Info);
    end;
  end;
  SortBenchmarks(List);
  Result := List;
end;

{ ---- 2. Pure stats --------------------------------------------------------- }

function Summarize(const ASamples: TRunSampleArray): TBenchStats;
var
  i, n, Timed: Integer;
  Sum: QWord;
  Mean, Variance, Diff: Double;
begin
  FillChar(Result, SizeOf(Result), 0);
  n := Length(ASamples);
  Result.Count := n;
  if n = 0 then
    Exit;

  { First pass: success/failure tally over ALL runs, and min/max/sum over the
    TIMED runs only (a run that failed to launch has no meaningful span, so
    its zero is excluded from the timing stats — it must not masquerade as
    the fastest run). }
  Result.MinNanos := High(QWord);
  Result.MaxNanos := 0;
  Sum := 0;
  Timed := 0;
  for i := 0 to n - 1 do
  begin
    if ASamples[i].LaunchOk and (ASamples[i].ExitCode = 0) then
      Inc(Result.SuccessCount)
    else
      Inc(Result.FailureCount);
    if not ASamples[i].LaunchOk then
      Continue;
    Inc(Timed);
    if ASamples[i].Nanos < Result.MinNanos then
      Result.MinNanos := ASamples[i].Nanos;
    if ASamples[i].Nanos > Result.MaxNanos then
      Result.MaxNanos := ASamples[i].Nanos;
    Sum := Sum + ASamples[i].Nanos;
  end;

  if Timed = 0 then
  begin
    Result.MinNanos := 0;
    Exit;
  end;

  Mean := Sum / Timed;
  Result.MeanNanos := Round(Mean);

  { Population variance over the timed runs, in Double — a derived statistic,
    not a measured span. }
  Variance := 0;
  for i := 0 to n - 1 do
  begin
    if not ASamples[i].LaunchOk then
      Continue;
    Diff := ASamples[i].Nanos - Mean;
    Variance := Variance + Diff * Diff;
  end;
  Variance := Variance / Timed;
  Result.StddevNanos := Round(Sqrt(Variance));
end;

function MedianNanos(const ASamples: TRunSampleArray): QWord;
var
  i, j, n, mid: Integer;
  Timed: array of QWord;
  t: QWord;
begin
  SetLength(Timed, 0);
  for i := 0 to High(ASamples) do
    if ASamples[i].LaunchOk then
    begin
      SetLength(Timed, Length(Timed) + 1);
      Timed[High(Timed)] := ASamples[i].Nanos;
    end;
  n := Length(Timed);
  if n = 0 then
    Exit(0);
  { insertion sort — tiny N }
  for i := 1 to n - 1 do
  begin
    t := Timed[i];
    j := i - 1;
    while (j >= 0) and (Timed[j] > t) do
    begin
      Timed[j + 1] := Timed[j];
      Dec(j);
    end;
    Timed[j + 1] := t;
  end;
  mid := n div 2;
  if (n and 1) = 1 then
    Result := Timed[mid]
  else
    Result := (Timed[mid - 1] + Timed[mid]) div 2;
end;

function ExtractChecksum(const AStdout: string): string;
var
  Lines: TStringList;
  i: Integer;
  L: string;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := AStdout;
    for i := Lines.Count - 1 downto 0 do
    begin
      L := Trim(Lines[i]);
      if L <> '' then
        Exit(L);
    end;
  finally
    Lines.Free;
  end;
end;

{ ---- 3. Baseline ------------------------------------------------------------ }

function BaselineToCsv(const ARecs: TBenchRecordArray): string;
var
  Doc: TCSVDocument;
  i: Integer;
begin
  Doc := TCSVDocument.Create;
  try
    Doc.AddRow('name');
    Doc.AddCell(0, 'median_ns');
    Doc.AddCell(0, 'mean_ns');
    Doc.AddCell(0, 'checksum');
    for i := 0 to High(ARecs) do
    begin
      Doc.AddRow(ARecs[i].Name);
      Doc.AddCell(i + 1, UIntToStr(ARecs[i].MedianNanos));
      Doc.AddCell(i + 1, UIntToStr(ARecs[i].MeanNanos));
      Doc.AddCell(i + 1, ARecs[i].Checksum);
    end;
    Result := Doc.CSVText;
  finally
    Doc.Free;
  end;
end;

function CsvToBaseline(const AText: string): TBenchRecordArray;
var
  Doc: TCSVDocument;
  Recs: TBenchRecordArray;
  i, cName, cMedian, cMean, cChecksum: Integer;
  R: TBenchRecord;
begin
  Doc := TCSVDocument.Create;
  try
    Doc.CSVText := AText;
    if Doc.RowCount < 1 then
      Exit(nil);
    { row 0 is the name,median_ns,… header }
    cName := Doc.IndexOfCol('name', 0);
    cMedian := Doc.IndexOfCol('median_ns', 0);
    cMean := Doc.IndexOfCol('mean_ns', 0);
    cChecksum := Doc.IndexOfCol('checksum', 0);
    if (cName < 0) or (cMedian < 0) then
      raise EPfBench.Create('baseline CSV: missing name/median_ns header');
    Recs := nil;
    for i := 1 to Doc.RowCount - 1 do
    begin
      R.Name := Doc.Cells[cName, i];
      R.MedianNanos := StrToQWordDef(Doc.Cells[cMedian, i], 0);
      if (cMean >= 0) and Doc.HasCell(cMean, i) then
        R.MeanNanos := StrToQWordDef(Doc.Cells[cMean, i], 0)
      else
        R.MeanNanos := 0;
      if (cChecksum >= 0) and Doc.HasCell(cChecksum, i) then
        R.Checksum := Doc.Cells[cChecksum, i]
      else
        R.Checksum := '';
      if R.Name = '' then
        Continue;
      SetLength(Recs, Length(Recs) + 1);
      Recs[High(Recs)] := R;
    end;
    Result := Recs;
  finally
    Doc.Free;
  end;
end;

procedure SaveBaseline(const APath: string; const ARecs: TBenchRecordArray);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := BaselineToCsv(ARecs);
    try
      L.SaveToFile(APath);
    except
      on E: Exception do
        raise EPfBench.CreateFmt('failed to write baseline %s: %s',
          [APath, E.Message]);
    end;
  finally
    L.Free;
  end;
end;

function LoadBaseline(const APath: string): TBenchRecordArray;
var
  L: TStringList;
begin
  if not FileExists(APath) then
    raise EPfBench.CreateFmt('baseline file not found: %s', [APath]);
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(APath);
    except
      on E: Exception do
        raise EPfBench.CreateFmt('failed to read baseline %s: %s',
          [APath, E.Message]);
    end;
    Result := CsvToBaseline(L.Text);
  finally
    L.Free;
  end;
end;

function FindRecord(const ARecs: TBenchRecordArray; const AName: string;
  out AIdx: Integer): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(ARecs) do
    if ARecs[i].Name = AName then
    begin
      AIdx := i;
      Exit(True);
    end;
  AIdx := -1;
  Result := False;
end;

function CompareBaseline(const ABaseline, ACurrent: TBenchRecordArray;
  AThresholdPct: Double): TDeltaArray;
var
  i, bi: Integer;
  D: TDelta;
begin
  SetLength(Result, Length(ACurrent));
  for i := 0 to High(ACurrent) do
  begin
    D.Name := ACurrent[i].Name;
    D.CurrentNanos := ACurrent[i].MedianNanos;
    D.BaselineNanos := 0;
    D.DeltaPct := 0;
    D.Regressed := False;
    D.InBaseline := FindRecord(ABaseline, ACurrent[i].Name, bi);
    if D.InBaseline then
    begin
      D.BaselineNanos := ABaseline[bi].MedianNanos;
      if D.BaselineNanos > 0 then
        D.DeltaPct := (Double(D.CurrentNanos) - Double(D.BaselineNanos)) /
          Double(D.BaselineNanos) * 100.0;
      D.Regressed := D.DeltaPct > AThresholdPct;
    end;
    Result[i] := D;
  end;
end;

function AnyRegressed(const ADeltas: TDeltaArray): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(ADeltas) do
    if ADeltas[i].Regressed then
      Exit(True);
  Result := False;
end;

{ ---- 4. A/B aggregation ----------------------------------------------------- }

function BuildAbRow(const AName, AChecksumA, AChecksumB: string;
  const ASamplesA, ASamplesB: TRunSampleArray): TAbRow;
begin
  Result.Name := AName;
  Result.ChecksumA := AChecksumA;
  Result.ChecksumB := AChecksumB;
  Result.ChecksumMatch := AChecksumA = AChecksumB;
  Result.StatsA := Summarize(ASamplesA);
  Result.StatsB := Summarize(ASamplesB);
  Result.MedianA := MedianNanos(ASamplesA);
  Result.MedianB := MedianNanos(ASamplesB);
  if Result.MedianB > 0 then
    Result.Speedup := Double(Result.MedianA) / Double(Result.MedianB)
  else
    Result.Speedup := 0;
  Result.Ok := Result.ChecksumMatch and
    (Result.StatsA.FailureCount = 0) and (Result.StatsB.FailureCount = 0);
  if not Result.ChecksumMatch then
    Result.Detail := 'CHECKSUM MISMATCH (A=' + AChecksumA + ' B=' + AChecksumB + ')'
  else if (Result.StatsA.FailureCount > 0) or (Result.StatsB.FailureCount > 0) then
    Result.Detail := 'run failure'
  else
    Result.Detail := 'ok';
end;

function AbAllOk(const ARows: TAbRowArray): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(ARows) do
    if not ARows[i].Ok then
      Exit(False);
  Result := True;
end;

{ ---- 5. Build / run --------------------------------------------------------- }

function ResolveCompiler(const ANameOrPath: string): string;
begin
  if (Pos('/', ANameOrPath) > 0) or (Pos(PathDelim, ANameOrPath) > 0) then
  begin
    if FileExists(ANameOrPath) then
      Result := ExpandFileName(ANameOrPath)
    else
      Result := '';
    Exit;
  end;
  Result := ExeSearch(ANameOrPath, GetEnvironmentVariable('PATH'));
end;

procedure BuildBenchmark(const ALprPath, ACompiler: string;
  const AFlags: array of string; const AOutBin, AScratchDir: string;
  AVerbose: Boolean);
var
  Args: array of string;
  i, n: Integer;
  PO: TProcOutcome;
begin
  ForceDirectories(AScratchDir);
  n := Length(AFlags);
  SetLength(Args, n + 3);
  for i := 0 to n - 1 do
    Args[i] := AFlags[i];
  Args[n] := '-FU' + AScratchDir;
  Args[n + 1] := '-o' + AOutBin;
  Args[n + 2] := ALprPath;

  PO := RunProcess(ACompiler, Args, ExtractFileDir(ALprPath));
  if not PO.Launched then
    raise EPfBench.CreateFmt('could not launch compiler %s', [ACompiler]);
  if AVerbose then
  begin
    if PO.Stdout <> '' then Write(PO.Stdout);
    if PO.Stderr <> '' then Write(StdErr, PO.Stderr);
  end;
  if PO.ExitCode <> 0 then
  begin
    { FPC reports errors on STDOUT; fall back to it when stderr is empty. }
    if Trim(PO.Stderr) <> '' then
      raise EPfBench.CreateFmt('build failed (exit %d): %s',
        [PO.ExitCode, Trim(PO.Stderr)])
    else if Trim(PO.Stdout) <> '' then
      raise EPfBench.CreateFmt('build failed (exit %d): %s',
        [PO.ExitCode, Trim(LastLines(PO.Stdout, 4))])
    else
      raise EPfBench.CreateFmt('build failed (exit %d)', [PO.ExitCode]);
  end;
  if not FileExists(AOutBin) then
    raise EPfBench.Create('build produced no binary');
end;

function ResolveBash: string;
begin
  Result := ExeSearch('bash', GetEnvironmentVariable('PATH'));
  if Result = '' then
    Result := '/bin/bash';
end;

function RunOnceCapped(const ABin: string; ATimeoutS: Integer;
  out AStdout: string; out AExitCode: Integer): Boolean;
var
  Cmd, Pin, PinCmd: string;
  PO: TProcOutcome;
begin
  AStdout := '';
  AExitCode := -1;
  if ATimeoutS < 1 then
    ATimeoutS := DEFAULT_TIME_CAP_S;
  { On hybrid P/E-core CPUs an unpinned run lands on either core type, which
    swings timings by ~2x. PF_BENCH_CPU=<cpulist> pins every run to the same
    CPU(s) via taskset so all samples are comparable. }
  Pin := GetEnvironmentVariable('PF_BENCH_CPU');
  if Pin <> '' then
    PinCmd := 'taskset -c ' + AnsiQuotedStr(Pin, '''') + ' '
  else
    PinCmd := '';
  Cmd := Format('ulimit -v %d && exec timeout %d %s%s',
    [MEM_CAP_KB, ATimeoutS, PinCmd, AnsiQuotedStr(ABin, '''')]);
  PO := RunProcess(ResolveBash, ['-c', Cmd], ExtractFileDir(ABin));
  if not PO.Launched then
    Exit(False);
  AStdout := PO.Stdout;
  AExitCode := PO.ExitCode;
  Result := AExitCode = 0;
end;

function TimedRun(const ABin: string; ATimeoutS: Integer): TRunSample;
var
  T0: QWord;
  Out_: string;
  ExitCode: Integer;
begin
  T0 := NowNanos;
  RunOnceCapped(ABin, ATimeoutS, Out_, ExitCode);
  Result.LaunchOk := ExitCode <> -1;
  Result.ExitCode := ExitCode;
  if Result.LaunchOk then
    Result.Nanos := NowNanos - T0
  else
    Result.Nanos := 0;
end;

function RunSamples(const ABin: string; ARuns, AWarmup, ATimeoutS: Integer):
  TRunSampleArray;
var
  i: Integer;
  Out_: string;
  ExitCode: Integer;
begin
  if ARuns < 1 then ARuns := 1;
  if AWarmup < 0 then AWarmup := 0;
  for i := 1 to AWarmup do
    RunOnceCapped(ABin, ATimeoutS, Out_, ExitCode);
  SetLength(Result, ARuns);
  for i := 0 to ARuns - 1 do
    Result[i] := TimedRun(ABin, ATimeoutS);
end;

procedure RunInterleaved(const ABinA, ABinB: string;
  ARuns, AWarmup, ATimeoutS: Integer;
  out ASamplesA, ASamplesB: TRunSampleArray);
var
  i: Integer;
  Out_: string;
  ExitCode: Integer;
begin
  if ARuns < 1 then ARuns := 1;
  if AWarmup < 0 then AWarmup := 0;
  for i := 1 to AWarmup do
  begin
    RunOnceCapped(ABinA, ATimeoutS, Out_, ExitCode);
    RunOnceCapped(ABinB, ATimeoutS, Out_, ExitCode);
  end;
  SetLength(ASamplesA, ARuns);
  SetLength(ASamplesB, ARuns);
  { ABAB… — alternate A and B on every scored iteration so any thermal or
    frequency drift over the run falls on both compilers equally. }
  for i := 0 to ARuns - 1 do
  begin
    ASamplesA[i] := TimedRun(ABinA, ATimeoutS);
    ASamplesB[i] := TimedRun(ABinB, ATimeoutS);
  end;
end;

procedure RemoveTree(const ADir: string);
var
  Info: TSearchRec;
  P: string;
begin
  if not DirectoryExists(ADir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, Info) = 0 then
  begin
    try
      repeat
        if (Info.Name = '.') or (Info.Name = '..') then
          Continue;
        P := IncludeTrailingPathDelimiter(ADir) + Info.Name;
        if (Info.Attr and faDirectory) <> 0 then
          RemoveTree(P)
        else
          DeleteFile(P);
      until FindNext(Info) <> 0;
    finally
      FindClose(Info);
    end;
  end;
  RemoveDir(ADir);
end;

end.
