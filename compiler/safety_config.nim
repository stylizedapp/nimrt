## compiler/safety_config.nim
##
## Central configuration and telemetry state for the Hybrid Memory-Safe Nim Compiler:
## - --mem-safe[:on|off|strict]
## - --safe-mode[:on|off|strict]
## - --check-safe-atf[:on|off|strict]
## - --atf-report:<path>

import std/[sets, strutils]
import options, condsyms, lineinfos, msgs

type
  SafetyStats* = object
    astModulesChecked*: int
    procsChecked*: int
    procsBorrowChecked*: int
    cFilesAudited*: int
    cLinesAudited*: int
    astViolations*: int
    atfViolations*: int

  CheckSuppression* = object
    file*: string
    line*: int
    detail*: string

  SafetyConfig* = object
    memSafeEnabled*: bool
    safeModeEnabled*: bool
    checkSafeAtfEnabled*: bool
    strictMode*: bool
    atfReportPath*: string
    userModuleNames*: HashSet[string]
    userModuleCStems*: HashSet[string]
    checkSuppressions*: seq[CheckSuppression]
    stats*: SafetyStats

var gSafety*: SafetyConfig

proc resetSafetyConfig*() =
  gSafety = SafetyConfig(
    memSafeEnabled: false,
    safeModeEnabled: false,
    checkSafeAtfEnabled: false,
    strictMode: false,
    atfReportPath: "",
    userModuleNames: initHashSet[string](),
    userModuleCStems: initHashSet[string](),
    checkSuppressions: @[],
    stats: SafetyStats()
  )

proc applyMemorySafeDefaults*(conf: ConfigRef) =
  ## Configures deterministic ORC memory management, thread analysis,
  ## view borrow checking, strict funcs, and runtime safety checks.
  if conf == nil:
    return

  if gSafety.memSafeEnabled or gSafety.safeModeEnabled:
    # Deterministic memory management (ORC) & thread-safety
    if conf.selectedGC notin {gcArc, gcOrc, gcAtomicArc}:
      conf.selectedGC = gcOrc
      defineSymbol(conf.symbols, "gcorc")
      defineSymbol(conf.symbols, "gcdestructors")
      incl conf.globalOptions, optSeqDestructors
      incl conf.globalOptions, optTinyRtti
      defineSymbol(conf.symbols, "nimSeqsV2")
      defineSymbol(conf.symbols, "nimV2")
      if conf.exc == excNone and conf.backend != backendCpp:
        conf.exc = excGoto

    conf.options.incl {
      optObjCheck, optFieldCheck, optRangeCheck, optBoundsCheck,
      optOverflowCheck, optAssert, optSinkInference, optCursorInference
    }
    conf.globalOptions.incl {optPanics, optThreads, optThreadAnalysis}
    conf.features.incl {strictFuncs}

    if gSafety.memSafeEnabled:
      defineSymbol(conf.symbols, "nimMemSafe")
    if gSafety.safeModeEnabled:
      defineSymbol(conf.symbols, "nimSafeMode")

  if gSafety.checkSafeAtfEnabled:
    defineSymbol(conf.symbols, "nimCheckSafeAtf")
    # Force full C codegen inspection when ATF auditing is active
    conf.globalOptions.incl optForceFullMake

proc processSafetySwitch*(switch, arg: string; info: TLineInfo; conf: ConfigRef): bool =
  let norm = switch.toLowerAscii().replace("_", "")
  case norm
  of "memsafe", "mem-safe":
    case arg.toLowerAscii()
    of "", "on":
      gSafety.memSafeEnabled = true
    of "strict":
      gSafety.memSafeEnabled = true
      gSafety.strictMode = true
    of "off":
      gSafety.memSafeEnabled = false
    else:
      localError(conf, info, "'on', 'off' or 'strict' expected, but '$1' found" % arg)
    applyMemorySafeDefaults(conf)
    return true
  of "safemode", "safe-mode":
    case arg.toLowerAscii()
    of "", "on":
      gSafety.safeModeEnabled = true
      gSafety.memSafeEnabled = true
    of "strict":
      gSafety.safeModeEnabled = true
      gSafety.memSafeEnabled = true
      gSafety.strictMode = true
    of "off":
      gSafety.safeModeEnabled = false
    else:
      localError(conf, info, "'on', 'off' or 'strict' expected, but '$1' found" % arg)
    applyMemorySafeDefaults(conf)
    return true
  of "checksafeatf", "check-safe-atf":
    case arg.toLowerAscii()
    of "", "on":
      gSafety.checkSafeAtfEnabled = true
    of "strict":
      gSafety.checkSafeAtfEnabled = true
      gSafety.strictMode = true
    of "off":
      gSafety.checkSafeAtfEnabled = false
    else:
      localError(conf, info, "'on', 'off' or 'strict' expected, but '$1' found" % arg)
    applyMemorySafeDefaults(conf)
    return true
  of "atfreport", "atf-report":
    if arg.len == 0:
      localError(conf, info, "argument for command line option expected: '--atf-report'")
    else:
      gSafety.atfReportPath = arg
    return true
  else:
    return false
