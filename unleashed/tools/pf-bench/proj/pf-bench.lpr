{ pf-bench — benchmark harness for the FPC Unleashed optimizer work.

  Discovers bench/*.bench.lpr programs (under --root; default: this repo's
  unleashed/tests), builds each with a selectable compiler + flag set, runs
  them with warm-up and repeated timed runs UNDER A MEMORY + TIME CAP, and
  folds the timings into min/mean/max/stddev plus a median. Every benchmark
  prints a single deterministic checksum line so pf-bench can assert two
  builds produced the SAME answer before comparing their speed — a
  miscompiling optimizer pass must FAIL the run, not win it.

  Two modes:

    pf-bench run  [opts]                     time every benchmark once
      --save FILE                            record per-benchmark medians to FILE
      --against FILE [--threshold PCT]       compare medians to a baseline; flag
                                             regressions past PCT% and exit non-zero

    pf-bench ab --compiler-a A --compiler-b B [opts]
                                             build every benchmark twice, INTERLEAVE
                                             the timed runs (ABAB…), print a per-
                                             benchmark speedup table

  Common options (both modes):
    --root DIR        benchmark tree root (default: <repo>/unleashed/tests,
                      resolved from the executable location)
    --filter SUBSTR   only benchmarks whose name contains SUBSTR
    --runs N          timed runs per benchmark (default 8)
    --warmup N        discarded warm-up runs (default 1)
    --timeout SECS    per-run wall-clock cap in seconds (default 120)
    --flags=…         extra compiler flags (whitespace-separated), appended
                      verbatim after the project's own -Fu<proj>/src (if any)
    --verbose         stream each build's compiler output

  run-only:  --compiler NAME|PATH (default: <repo>/fpcu.sh, else fpc)
  ab-only:   --compiler-a / --compiler-b NAME|PATH (required)
             --flags-a=… / --flags-b=…  per-side extra flags

  Value flags starting with '-' must use the '=' form (--flags=-O2, not
  --flags -O2): the parser will not consume a following token that itself
  begins with '-'.

  Exit codes: 0 = success; 1 = usage/IO error, a build/run failure, a checksum
  mismatch, or (with --against) a regression past the threshold.

  Thin shell over pfbench.engine. }
program pfbench;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, pfbench.engine;

const
  EXIT_ERROR = 1;
  DEFAULT_RUNS = 8;
  DEFAULT_WARMUP = 1;

{ ---- logging ---------------------------------------------------------------- }

procedure LogInfo(const AMsg: string);
begin
  WriteLn(AMsg);
end;

procedure LogWarn(const AMsg: string);
begin
  WriteLn(StdErr, 'WARN: ', AMsg);
end;

procedure LogError(const AMsg: string);
begin
  WriteLn(StdErr, 'ERROR: ', AMsg);
end;

{ ---- duration formatting ----------------------------------------------------

  One token, no embedded spaces (the A/B table is consumed with awk). }
function FormatDuration(ANanos: QWord): string;
begin
  if ANanos >= 1000000000 then
    Result := Format('%.3fs', [ANanos / 1e9])
  else if ANanos >= 1000000 then
    Result := Format('%.2fms', [ANanos / 1e6])
  else if ANanos >= 1000 then
    Result := Format('%.2fus', [ANanos / 1e3])
  else
    Result := Format('%uns', [ANanos]);
end;

{ ---- option parsing ---------------------------------------------------------

  --name=value | --name value (value must not start with '-') for value
  options; --name for boolean flags. Unknown options are an error. }
type
  TArgParser = class
  private
    FNames, FValues: TStringList;
    FError: string;
  public
    constructor Create;
    destructor Destroy; override;
    function Parse(const AArgs: array of string;
      const AValueOpts, ABoolFlags: array of string): Boolean;
    function GetOption(const AName, ADefault: string): string;
    function HasFlag(const AName: string): Boolean;
    property Error: string read FError;
  end;

constructor TArgParser.Create;
begin
  FNames := TStringList.Create;
  FValues := TStringList.Create;
end;

destructor TArgParser.Destroy;
begin
  FValues.Free;
  FNames.Free;
  inherited;
end;

function IndexIn(const AName: string; const AList: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AList) do
    if AList[i] = AName then
      Exit(True);
  Result := False;
end;

function TArgParser.Parse(const AArgs: array of string;
  const AValueOpts, ABoolFlags: array of string): Boolean;
var
  i, eq: Integer;
  Arg, Name, Value: string;
begin
  FError := '';
  i := 0;
  while i <= High(AArgs) do
  begin
    Arg := AArgs[i];
    if Copy(Arg, 1, 2) <> '--' then
    begin
      FError := 'unexpected argument: ' + Arg;
      Exit(False);
    end;
    Name := Copy(Arg, 3, MaxInt);
    eq := Pos('=', Name);
    if eq > 0 then
    begin
      Value := Copy(Name, eq + 1, MaxInt);
      Name := Copy(Name, 1, eq - 1);
      if not IndexIn(Name, AValueOpts) then
      begin
        FError := 'unknown option: --' + Name;
        Exit(False);
      end;
      FNames.Add(Name);
      FValues.Add(Value);
    end
    else if IndexIn(Name, ABoolFlags) then
    begin
      FNames.Add(Name);
      FValues.Add('1');
    end
    else if IndexIn(Name, AValueOpts) then
    begin
      { consume the next token as the value, unless it looks like an option }
      if (i < High(AArgs)) and (Copy(AArgs[i + 1], 1, 1) <> '-') then
      begin
        Inc(i);
        FNames.Add(Name);
        FValues.Add(AArgs[i]);
      end
      else
      begin
        FError := 'option --' + Name + ' needs a value (use --' + Name +
          '=… for values starting with ''-'')';
        Exit(False);
      end;
    end
    else
    begin
      FError := 'unknown option: --' + Name;
      Exit(False);
    end;
    Inc(i);
  end;
  Result := True;
end;

function TArgParser.GetOption(const AName, ADefault: string): string;
var
  i: Integer;
begin
  i := FNames.IndexOf(AName);
  if i >= 0 then
    Result := FValues[i]
  else
    Result := ADefault;
end;

function TArgParser.HasFlag(const AName: string): Boolean;
begin
  Result := FNames.IndexOf(AName) >= 0;
end;

{ ---- defaults resolved from the executable location ------------------------- }

{ …/unleashed/tools/pf-bench/bin/pf-bench → the repo root, 4 levels up. }
function RepoRoot: string;
var
  D: string;
  i: Integer;
begin
  D := ExtractFileDir(ExpandFileName(ParamStr(0)));
  for i := 1 to 4 do
    D := ExtractFileDir(D);
  Result := D;
end;

function DefaultBenchRoot: string;
var
  Candidate: string;
begin
  Candidate := RepoRoot + PathDelim + 'unleashed' + PathDelim + 'tests';
  if DirectoryExists(Candidate + PathDelim + 'bench') then
    Result := Candidate
  else
    Result := GetCurrentDir;
end;

{ The in-tree compiler wrapper (adds the RTL + packages unit paths), when this
  binary lives in its repo; plain fpc otherwise. }
function DefaultCompiler: string;
var
  Candidate: string;
begin
  Candidate := RepoRoot + PathDelim + 'fpcu.sh';
  if FileExists(Candidate) then
    Result := Candidate
  else
    Result := 'fpc';
end;

{ ---- small helpers ----------------------------------------------------------- }

{ Split a whitespace-separated flag string into an argv array (empty tokens
  dropped). Quoting is NOT supported — paths with spaces are out of scope. }
function SplitFlags(const AFlags: string): TStringArray;
var
  Parts: TStringList;
  i: Integer;
begin
  SetLength(Result, 0);
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := False; { split on any whitespace run }
    Parts.DelimitedText := StringReplace(Trim(AFlags), #9, ' ', [rfReplaceAll]);
    for i := 0 to Parts.Count - 1 do
      if Trim(Parts[i]) <> '' then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Parts[i];
      end;
  finally
    Parts.Free;
  end;
end;

function Concat2(const A, B: array of string): TStringArray;
var
  i: Integer;
begin
  SetLength(Result, Length(A) + Length(B));
  for i := 0 to High(A) do Result[i] := A[i];
  for i := 0 to High(B) do Result[Length(A) + i] := B[i];
end;

{ The standard flags for building a benchmark: the project's own src dir on
  the unit path, when it has one. RTL/package paths come from the compiler
  wrapper (fpcu.sh) or the caller's --flags. }
function BaseFlags(const ABench: TBenchmark): TStringArray;
var
  ProjSrc: string;
begin
  SetLength(Result, 0);
  ProjSrc := IncludeTrailingPathDelimiter(ABench.ProjectDir) + 'src';
  if DirectoryExists(ProjSrc) then
  begin
    SetLength(Result, 1);
    Result[0] := '-Fu' + ProjSrc;
  end;
end;

{ A unique scratch dir under the system temp for one build. }
function ScratchDir(const ATag: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) +
    Format('pfbench-%s-%d-%d', [ATag, GetProcessID, Random(1000000)]);
end;

{ Percent with an explicit sign (FPC's Format has no printf-style '+' flag). }
function FormatPct(AValue: Double): string;
begin
  if AValue >= 0 then
    Result := '+' + Format('%.2f', [AValue]) + '%'
  else
    Result := Format('%.2f', [AValue]) + '%';
end;

function FormatSpeedup(AValue: Double): string;
begin
  if AValue <= 0 then
    Result := '   n/a'
  else
    Result := Format('%6.3fx', [AValue]);
end;

function ApplyFilter(const ABenches: TBenchmarkArray; const AFilter: string):
  TBenchmarkArray;
var
  i: Integer;
begin
  SetLength(Result, 0);
  for i := 0 to High(ABenches) do
    if (AFilter = '') or (Pos(AFilter, ABenches[i].Name) > 0) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := ABenches[i];
    end;
end;

{ ---- Shared option parsing --------------------------------------------------- }

type
  TCommonOpts = record
    Root: string;
    Filter: string;
    Runs, Warmup, TimeoutS: Integer;
    Verbose: Boolean;
  end;

function ParseCommon(ACli: TArgParser; out AOpts: TCommonOpts): Boolean;
var
  S: string;
begin
  Result := True;
  AOpts.Root := ACli.GetOption('root', DefaultBenchRoot);
  AOpts.Filter := ACli.GetOption('filter', '');
  AOpts.Verbose := ACli.HasFlag('verbose') or ACli.HasFlag('v');

  AOpts.Runs := DEFAULT_RUNS;
  S := ACli.GetOption('runs', '');
  if (S <> '') and (not TryStrToInt(S, AOpts.Runs)) then
  begin
    LogError('invalid --runs: ' + S); Exit(False);
  end;
  if AOpts.Runs < 1 then AOpts.Runs := 1;

  AOpts.Warmup := DEFAULT_WARMUP;
  S := ACli.GetOption('warmup', '');
  if (S <> '') and (not TryStrToInt(S, AOpts.Warmup)) then
  begin
    LogError('invalid --warmup: ' + S); Exit(False);
  end;
  if AOpts.Warmup < 0 then AOpts.Warmup := 0;

  AOpts.TimeoutS := DEFAULT_TIME_CAP_S;
  S := ACli.GetOption('timeout', '');
  if (S <> '') and (not TryStrToInt(S, AOpts.TimeoutS)) then
  begin
    LogError('invalid --timeout: ' + S); Exit(False);
  end;
  if AOpts.TimeoutS < 1 then AOpts.TimeoutS := DEFAULT_TIME_CAP_S;
end;

{ Discover + filter, reporting when nothing matched. }
function DiscoverFiltered(const AOpts: TCommonOpts; out ABenches: TBenchmarkArray):
  Boolean;
begin
  try
    ABenches := DiscoverBenchmarks(AOpts.Root);
  except
    on E: EPfBench do
    begin
      LogError(E.Message);
      Exit(False);
    end;
  end;
  ABenches := ApplyFilter(ABenches, AOpts.Filter);
  if Length(ABenches) = 0 then
    LogWarn('no benchmarks (bench/*.bench.lpr) matched');
  Result := True;
end;

{ ---- run mode ----------------------------------------------------------------- }

function CmdRun(const AArgs: array of string): Integer;
var
  Cli: TArgParser;
  Opts: TCommonOpts;
  Benches: TBenchmarkArray;
  Compiler, CompilerPath, SavePath, AgainstPath, Bin, Scratch: string;
  ExtraFlags, Flags: TStringArray;
  i, Failures: Integer;
  Samples: TRunSampleArray;
  Stats: TBenchStats;
  Checksum, ProbeOut: string;
  ProbeExit: Integer;
  Recs: TBenchRecordArray;
  Rec: TBenchRecord;
  Threshold: Double;
  ThreshStr: string;
  Baseline: TBenchRecordArray;
  Deltas: TDeltaArray;
begin
  Cli := TArgParser.Create;
  try
    if not Cli.Parse(AArgs,
      ['root', 'filter', 'runs', 'warmup', 'timeout', 'compiler', 'flags',
       'save', 'against', 'threshold'],
      ['verbose', 'v']) then
    begin
      LogError(Cli.Error);
      Exit(EXIT_ERROR);
    end;
    if not ParseCommon(Cli, Opts) then Exit(EXIT_ERROR);

    Compiler := Cli.GetOption('compiler', DefaultCompiler);
    CompilerPath := ResolveCompiler(Compiler);
    if CompilerPath = '' then
    begin
      LogError('compiler not found: ' + Compiler);
      Exit(EXIT_ERROR);
    end;

    ExtraFlags := SplitFlags(Cli.GetOption('flags', ''));
    SavePath := Cli.GetOption('save', '');
    AgainstPath := Cli.GetOption('against', '');
    ThreshStr := Cli.GetOption('threshold', '5');
    if not TryStrToFloat(ThreshStr, Threshold) then
    begin
      LogError('invalid --threshold: ' + ThreshStr);
      Exit(EXIT_ERROR);
    end;

    if not DiscoverFiltered(Opts, Benches) then Exit(EXIT_ERROR);

    LogInfo(Format('run: %d benchmark(s), compiler=%s, runs=%d warmup=%d',
      [Length(Benches), CompilerPath, Opts.Runs, Opts.Warmup]));

    Failures := 0;
    SetLength(Recs, 0);
    for i := 0 to High(Benches) do
    begin
      Flags := Concat2(BaseFlags(Benches[i]), ExtraFlags);
      Scratch := ScratchDir('run');
      Bin := IncludeTrailingPathDelimiter(Scratch) +
        StringReplace(Benches[i].Name, '/', '_', [rfReplaceAll]);
      try
        try
          BuildBenchmark(Benches[i].LprPath, CompilerPath, Flags, Bin,
            Scratch, Opts.Verbose);
        except
          on E: EPfBench do
          begin
            LogError(Format('  BUILD-FAIL  %-24s %s', [Benches[i].Name, E.Message]));
            Inc(Failures);
            Continue;
          end;
        end;
        { checksum probe (one capped run) }
        RunOnceCapped(Bin, Opts.TimeoutS, ProbeOut, ProbeExit);
        Checksum := ExtractChecksum(ProbeOut);
        if ProbeExit <> 0 then
        begin
          LogError(Format('  RUN-FAIL    %-24s exit %d', [Benches[i].Name, ProbeExit]));
          Inc(Failures);
          Continue;
        end;
        Samples := RunSamples(Bin, Opts.Runs, Opts.Warmup, Opts.TimeoutS);
        Stats := Summarize(Samples);
        Rec.Name := Benches[i].Name;
        Rec.MedianNanos := MedianNanos(Samples);
        Rec.MeanNanos := Stats.MeanNanos;
        Rec.Checksum := Checksum;
        SetLength(Recs, Length(Recs) + 1);
        Recs[High(Recs)] := Rec;
        LogInfo(Format('  %-24s median %s  mean %s  min %s  cksum %s',
          [Benches[i].Name, FormatDuration(Rec.MedianNanos),
           FormatDuration(Stats.MeanNanos), FormatDuration(Stats.MinNanos),
           Checksum]));
      finally
        RemoveTree(Scratch);
      end;
    end;

    if SavePath <> '' then
    begin
      try
        SaveBaseline(SavePath, Recs);
      except
        on E: EPfBench do
        begin
          LogError(E.Message);
          Exit(EXIT_ERROR);
        end;
      end;
      LogInfo('saved baseline to ' + SavePath);
    end;

    if AgainstPath <> '' then
    begin
      try
        Baseline := LoadBaseline(AgainstPath);
      except
        on E: EPfBench do
        begin
          LogError(E.Message);
          Exit(EXIT_ERROR);
        end;
      end;
      Deltas := CompareBaseline(Baseline, Recs, Threshold);
      LogInfo(Format('compare vs %s (threshold %.2f%%):', [AgainstPath, Threshold]));
      for i := 0 to High(Deltas) do
      begin
        if not Deltas[i].InBaseline then
          LogInfo(Format('  %-24s (new, no baseline)', [Deltas[i].Name]))
        else if Deltas[i].Regressed then
          LogError(Format('  %-24s %9s  REGRESSION  (%s -> %s)',
            [Deltas[i].Name, FormatPct(Deltas[i].DeltaPct),
             FormatDuration(Deltas[i].BaselineNanos),
             FormatDuration(Deltas[i].CurrentNanos)]))
        else
          LogInfo(Format('  %-24s %9s  (%s -> %s)',
            [Deltas[i].Name, FormatPct(Deltas[i].DeltaPct),
             FormatDuration(Deltas[i].BaselineNanos),
             FormatDuration(Deltas[i].CurrentNanos)]));
      end;
      if AnyRegressed(Deltas) then
      begin
        LogError('FAIL: one or more benchmarks regressed past the threshold');
        Exit(EXIT_ERROR);
      end;
      LogInfo('OK: no benchmark regressed past the threshold');
    end;

    if Failures > 0 then
    begin
      LogError(Format('FAIL: %d benchmark(s) failed to build/run', [Failures]));
      Exit(EXIT_ERROR);
    end;
    Result := 0;
  finally
    Cli.Free;
  end;
end;

{ ---- ab mode ------------------------------------------------------------------ }

function CmdAb(const AArgs: array of string): Integer;
var
  Cli: TArgParser;
  Opts: TCommonOpts;
  Benches: TBenchmarkArray;
  CompA, CompB, PathA, PathB, BinA, BinB, ScratchA, ScratchB: string;
  FlagsA, FlagsB, ExtraA, ExtraB: TStringArray;
  i, Failures: Integer;
  SamplesA, SamplesB: TRunSampleArray;
  CkA, CkB, ProbeOut, BuildErr: string;
  ProbeExit: Integer;
  Rows: TAbRowArray;
  Row: TAbRow;
begin
  Cli := TArgParser.Create;
  try
    if not Cli.Parse(AArgs,
      ['root', 'filter', 'runs', 'warmup', 'timeout', 'compiler-a', 'compiler-b',
       'flags', 'flags-a', 'flags-b'],
      ['verbose', 'v']) then
    begin
      LogError(Cli.Error);
      Exit(EXIT_ERROR);
    end;
    if not ParseCommon(Cli, Opts) then Exit(EXIT_ERROR);

    CompA := Cli.GetOption('compiler-a', '');
    CompB := Cli.GetOption('compiler-b', '');
    if (CompA = '') or (CompB = '') then
    begin
      LogError('ab mode requires --compiler-a and --compiler-b');
      Exit(EXIT_ERROR);
    end;
    PathA := ResolveCompiler(CompA);
    PathB := ResolveCompiler(CompB);
    if PathA = '' then begin LogError('compiler-a not found: ' + CompA); Exit(EXIT_ERROR); end;
    if PathB = '' then begin LogError('compiler-b not found: ' + CompB); Exit(EXIT_ERROR); end;

    { --flags applies to both sides; --flags-a / --flags-b add per-side. }
    ExtraA := Concat2(SplitFlags(Cli.GetOption('flags', '')),
                      SplitFlags(Cli.GetOption('flags-a', '')));
    ExtraB := Concat2(SplitFlags(Cli.GetOption('flags', '')),
                      SplitFlags(Cli.GetOption('flags-b', '')));

    if not DiscoverFiltered(Opts, Benches) then Exit(EXIT_ERROR);

    LogInfo(Format('ab: %d benchmark(s)', [Length(Benches)]));
    LogInfo('  A = ' + PathA);
    LogInfo('  B = ' + PathB);

    Failures := 0;
    SetLength(Rows, 0);
    for i := 0 to High(Benches) do
    begin
      FlagsA := Concat2(BaseFlags(Benches[i]), ExtraA);
      FlagsB := Concat2(BaseFlags(Benches[i]), ExtraB);
      ScratchA := ScratchDir('a');
      ScratchB := ScratchDir('b');
      BinA := IncludeTrailingPathDelimiter(ScratchA) + 'a';
      BinB := IncludeTrailingPathDelimiter(ScratchB) + 'b';
      try
        BuildErr := '';
        try
          BuildBenchmark(Benches[i].LprPath, PathA, FlagsA, BinA, ScratchA, Opts.Verbose);
        except
          on E: EPfBench do BuildErr := 'BUILD-FAIL(A) ' + E.Message;
        end;
        if BuildErr = '' then
          try
            BuildBenchmark(Benches[i].LprPath, PathB, FlagsB, BinB, ScratchB, Opts.Verbose);
          except
            on E: EPfBench do BuildErr := 'BUILD-FAIL(B) ' + E.Message;
          end;
        if BuildErr <> '' then
        begin
          LogError(Format('  %-24s %s', [Benches[i].Name, BuildErr]));
          Inc(Failures);
          Continue;
        end;
        RunOnceCapped(BinA, Opts.TimeoutS, ProbeOut, ProbeExit); CkA := ExtractChecksum(ProbeOut);
        RunOnceCapped(BinB, Opts.TimeoutS, ProbeOut, ProbeExit); CkB := ExtractChecksum(ProbeOut);
        RunInterleaved(BinA, BinB, Opts.Runs, Opts.Warmup, Opts.TimeoutS, SamplesA, SamplesB);
        Row := BuildAbRow(Benches[i].Name, CkA, CkB, SamplesA, SamplesB);
        SetLength(Rows, Length(Rows) + 1);
        Rows[High(Rows)] := Row;
      finally
        RemoveTree(ScratchA);
        RemoveTree(ScratchB);
      end;
    end;

    { Speedup table. }
    Writeln;
    Writeln(Format('%-24s %14s %14s %9s  %s',
      ['benchmark', 'A median', 'B median', 'speedup', 'status']));
    Writeln(StringOfChar('-', 78));
    for i := 0 to High(Rows) do
      Writeln(Format('%-24s %14s %14s %9s  %s',
        [Rows[i].Name, FormatDuration(Rows[i].MedianA),
         FormatDuration(Rows[i].MedianB), FormatSpeedup(Rows[i].Speedup),
         Rows[i].Detail]));
    Writeln(StringOfChar('-', 78));
    Writeln('speedup = A median / B median  (>1 means B is faster)');

    if not AbAllOk(Rows) then
    begin
      LogError('FAIL: a checksum mismatch or run failure occurred — speed numbers are void');
      Exit(EXIT_ERROR);
    end;
    if Failures > 0 then
    begin
      LogError(Format('FAIL: %d benchmark(s) failed to build', [Failures]));
      Exit(EXIT_ERROR);
    end;
    Result := 0;
  finally
    Cli.Free;
  end;
end;

{ ---- usage --------------------------------------------------------------------- }

procedure PrintUsage;
begin
  Writeln('pf-bench — benchmark harness (FPC Unleashed)');
  Writeln;
  Writeln('Usage:');
  Writeln('  pf-bench run [--compiler NAME|PATH] [--save FILE]');
  Writeln('               [--against FILE [--threshold PCT]] [common opts]');
  Writeln('  pf-bench ab  --compiler-a A --compiler-b B');
  Writeln('               [--flags-a=…] [--flags-b=…] [common opts]');
  Writeln;
  Writeln('Common: --root DIR --filter SUBSTR --runs N --warmup N --timeout SECS');
  Writeln('        --flags=… --verbose');
  Writeln;
  Writeln('Benchmarks are bench/*.bench.lpr programs that run a fixed workload and');
  Writeln('print a single checksum line; pf-bench asserts A and B agree before it');
  Writeln('trusts any speed number.');
end;

{ Collect ParamStr(2..) as the sub-argv for a subcommand. }
function SubArgs: TStringArray;
var
  i: Integer;
begin
  SetLength(Result, 0);
  for i := 2 to ParamCount do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := ParamStr(i);
  end;
end;

var
  Verb: string;
begin
  Randomize;
  if ParamCount < 1 then
  begin
    PrintUsage;
    Halt(EXIT_ERROR);
  end;
  Verb := ParamStr(1);
  if (Verb = '--help') or (Verb = '-h') or (Verb = 'help') then
  begin
    PrintUsage;
    Halt(0);
  end
  else if Verb = 'run' then
    Halt(CmdRun(SubArgs))
  else if Verb = 'ab' then
    Halt(CmdAb(SubArgs))
  else
  begin
    LogError('unknown command: ' + Verb + ' (expected run or ab)');
    Halt(EXIT_ERROR);
  end;
end.
