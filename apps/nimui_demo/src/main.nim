## =============================================================================
## NimUI Singularity Lab — Relativistic Black Hole & Star Astrophysical Simulation
## Built with NimUI: pure Vulkan 1.1+ SDF, Zero-Alloc Retained UI,
## Checkboxes, RadioGroups, Sliders, Dropdowns, Tooltips, VirtualList, TextArea, Clipboard.
## =============================================================================

import std/[strformat, strutils, os, monotimes, times, algorithm, random, math, cpuinfo]
when defined(windows):
  import winlean

import nimui
import nimui/html_css
import nimui/gpu/[vulkan_api, vulkan_backend, font_atlas]
import nimui/window
import corex/signals

# =============================================================================
# Design Tokens (Monochrome High-Craft System)
# =============================================================================

const
  ColBgPage*      = 0x09090BFF'u32  # Obsidian deep canvas background
  ColBgSurface*   = 0x121215FF'u32  # Primary card surface
  ColBgRaised*    = 0x18181DFF'u32  # Control surface
  ColBgHover*     = 0x222228FF'u32  # Hover state
  ColBgActive*    = 0x2A2A33FF'u32  # Active / selected state
  ColBorder*      = 0x1E1E24FF'u32  # Subtle layout border
  ColBorderCtl*   = 0x2E2E38FF'u32  # Interactive element border
  ColFocusRing*   = 0x666675FF'u32  # Focus ring border
  ColTextPrim*    = 0xF4F4F6FF'u32  # High-contrast primary text
  ColTextSec*     = 0x8E8E96FF'u32  # Secondary metadata text
  ColTextTert*    = 0x54545EFF'u32  # Muted annotations
  ColCanvasBg*    = 0x060608FF'u32  # Space viewport background
  ColCanvasBrd*   = 0x18181EFF'u32  # Viewport outer border

# =============================================================================
# Win32 Diagnostics & Memory
# =============================================================================

when defined(windows):
  type
    BOOL = int32
    HANDLE = pointer
    DWORD = uint32

    PROCESS_MEMORY_COUNTERS = object
      cb: uint32
      pageFaultCount: uint32
      peakWorkingSetSize: uint
      workingSetSize: uint
      quotaPeakPagedPoolUsage: uint
      quotaPagedPoolUsage: uint
      quotaPeakNonPagedPoolUsage: uint
      quotaNonPagedPoolUsage: uint
      pagefileUsage: uint
      peakPagefileUsage: uint

    FILETIME = object
      dwLowDateTime: uint32
      dwHighDateTime: uint32

  proc GetProcessMemoryInfo(hProcess: HANDLE, ppsmemCounters: ptr PROCESS_MEMORY_COUNTERS, cb: uint32): BOOL {.stdcall, dynlib: "psapi", importc: "GetProcessMemoryInfo", raises: [].}
  proc EmptyWorkingSet(hProcess: HANDLE): BOOL {.stdcall, dynlib: "psapi", importc: "EmptyWorkingSet", raises: [].}
  proc GetSystemTimes(lpIdleTime, lpKernelTime, lpUserTime: ptr FILETIME): BOOL {.stdcall, dynlib: "kernel32", importc: "GetSystemTimes", raises: [].}
  proc GetProcessTimes(hProcess: HANDLE, lpCreationTime, lpExitTime, lpKernelTime, lpUserTime: ptr FILETIME): BOOL {.stdcall, dynlib: "kernel32", importc: "GetProcessTimes", raises: [].}
  proc GetCurrentProcess(): HANDLE {.stdcall, dynlib: "kernel32", importc: "GetCurrentProcess", raises: [].}

  proc fileTimeToUint64(ft: FILETIME): uint64 {.inline, raises: [].} =
    (uint64(ft.dwHighDateTime) shl 32) or uint64(ft.dwLowDateTime)

  var gLastIdle, gLastKernel, gLastUser: uint64
  var gLastProcKernel, gLastProcUser: uint64
  var gCachedCpuUsage: float32 = 0.0f

  proc querySystemCpuLoad(): float32 {.raises: [].} =
    var idleFt, kernelFt, userFt: FILETIME
    if GetSystemTimes(addr idleFt, addr kernelFt, addr userFt) == 0:
      return gCachedCpuUsage
    let idle = fileTimeToUint64(idleFt)
    let kernel = fileTimeToUint64(kernelFt)
    let user = fileTimeToUint64(userFt)
    if gLastIdle != 0:
      let idleDiff = idle - gLastIdle
      let kernelDiff = kernel - gLastKernel
      let userDiff = user - gLastUser
      let total = kernelDiff + userDiff
      if total > 0:
        let busy = total - min(idleDiff, total)
        gCachedCpuUsage = float32(busy) * 100.0f / float32(total)
    gLastIdle = idle
    gLastKernel = kernel
    gLastUser = user
    gCachedCpuUsage

  proc querySelfCpuUsage(elapsedSec: float): tuple[totalPct: float32, userPct: float32, kernelPct: float32] {.raises: [].} =
    var createFt, exitFt, kernelFt, userFt: FILETIME
    if GetProcessTimes(GetCurrentProcess(), addr createFt, addr exitFt, addr kernelFt, addr userFt) == 0:
      return (0.0f, 0.0f, 0.0f)
    let k = fileTimeToUint64(kernelFt)
    let u = fileTimeToUint64(userFt)
    var totalPct: float32 = 0.0f
    var userPct: float32 = 0.0f
    var kernPct: float32 = 0.0f
    if gLastProcKernel != 0 and elapsedSec > 0.0001:
      let kDiff = k - gLastProcKernel
      let uDiff = u - gLastProcUser
      let totalDiff = kDiff + uDiff
      let numCores = float32(countProcessors())
      let elapsed100Ns = elapsedSec * 10_000_000.0
      totalPct = min(100.0f, (float32(totalDiff) / float32(elapsed100Ns)) * 100.0f / numCores)
      userPct = min(100.0f, (float32(uDiff) / float32(elapsed100Ns)) * 100.0f / numCores)
      kernPct = min(100.0f, (float32(kDiff) / float32(elapsed100Ns)) * 100.0f / numCores)
    gLastProcKernel = k
    gLastProcUser = u
    (totalPct, userPct, kernPct)

  proc queryWorkingSetBytes(): tuple[wsBytes: uint, commitBytes: uint] {.raises: [].} =
    var pmc: PROCESS_MEMORY_COUNTERS
    pmc.cb = uint32(sizeof(PROCESS_MEMORY_COUNTERS))
    if GetProcessMemoryInfo(GetCurrentProcess(), addr pmc, pmc.cb) != 0:
      return (pmc.workingSetSize, pmc.pagefileUsage)
    (0'u, 0'u)
else:
  proc querySystemCpuLoad(): float32 {.raises: [].} = 0.0f
  proc querySelfCpuUsage(elapsedSec: float): tuple[totalPct, userPct, kernelPct: float32] {.raises: [].} = (0.0f, 0.0f, 0.0f)
  proc queryWorkingSetBytes(): tuple[wsBytes: uint, commitBytes: uint] {.raises: [].} = (0'u, 0'u)
  proc EmptyWorkingSet(hProcess: pointer): int32 {.raises: [].} = 1'i32

# =============================================================================
# Astrophysical Black Hole Simulation Types & Engine
# =============================================================================

type
  GravityMetric* = enum
    gmSchwarzschild = 0
    gmKerr = 1
    gmNewtonian = 2

  SpectralClass* = enum
    scBlueGiant  # Class O/B (Blue-white, hot)
    scWhiteStar  # Class A/F (Pure white)
    scYellowDwarf# Class G (Sun-like, warm white/yellow)
    scRedDwarf   # Class M (Red-orange, cool)
    scNeutronStar# Pulsar (High density, cyan glow)

  StarStatus* = enum
    ssOrbiting = 0
    ssTidalDisrupted = 1

  AccretionParticle* = object
    pos*: array[2, float32]
    vel*: array[2, float32]
    radius*: float32
    angle*: float32
    speed*: float32
    life*: float32
    color*: uint32

  JetParticle* = object
    pos*: array[2, float32]
    vel*: array[2, float32]
    life*: float32
    maxLife*: float32
    size*: float32
    color*: uint32

const
  MaxStars = 4000
  MaxAccretion = 250
  MaxJet = 100
  MaxTrailPoints = 8

type
  StarSoA* = ref object
    count*: int
    posX*: array[MaxStars, float32]
    posY*: array[MaxStars, float32]
    velX*: array[MaxStars, float32]
    velY*: array[MaxStars, float32]
    mass*: array[MaxStars, float32]
    radius*: array[MaxStars, float32]
    color*: array[MaxStars, uint32]
    status*: array[MaxStars, uint8]      # 0 = Orbiting, 1 = TidalDisrupted
    spectral*: array[MaxStars, uint8]    # SpectralClass
    id*: array[MaxStars, int32]
    trailX*: array[MaxStars * MaxTrailPoints, float32]
    trailY*: array[MaxStars * MaxTrailPoints, float32]
    trailHead*: array[MaxStars, uint8]
    trailCount*: array[MaxStars, uint8]

  BlackHoleSim* = object
    centerX*: float32
    centerY*: float32
    mass*: float32        # in 10^6 solar masses (1.0 .. 25.0)
    spin*: float32        # Kerr spin parameter a* (-0.99 .. +0.99)
    metric*: GravityMetric
    schwarzschildR*: float32 # Rs in pixels
    photonR*: float32        # Rph = 1.5 * Rs
    rocheR*: float32         # R_roche ~ 2.6 * Rs
    viscosity*: float32      # Accretion drag (0.0 .. 0.05)
    timeDilation*: float32   # Simulation speed (0.1 .. 5.0)
    
    # Visual Flags
    showAccretion*: bool
    showPhotonSphere*: bool
    showJets*: bool
    showTidalDisrupt*: bool
    showTrails*: bool
    
    # State
    isPaused*: bool
    selectedStarId*: int
    stars*: StarSoA
    accretion*: seq[AccretionParticle]
    jets*: seq[JetParticle]
    nextStarId*: int
    consumedCount*: int
    disruptedCount*: int
    simTimeSec*: float32
    trailTick*: int
    
    # Camera Viewport
    zoom*: float32
    targetZoom*: float32
    panX*: float32
    panY*: float32
    isPanning*: bool
    isFlinging*: bool
    flingStart*: array[2, float32]
    flingCurrent*: array[2, float32]

# Star colors by spectral class
const
  ColStarBlue*    = 0xA4C8FFFF'u32  # 0xB5D5FFFF
  ColStarWhite*   = 0xF0F4FFFF'u32
  ColStarYellow*  = 0xFFE6A0FF'u32
  ColStarRed*     = 0xFF7A60FF'u32
  ColStarCyan*    = 0x70F0FFFF'u32
  ColHorizon*     = 0x020204FF'u32  # Pure black hole interior
  ColPhotonRing*  = 0xEDECE8FF'u32  # Intense relativistic photon ring
  ColErgoRing*    = 0x48485588'u32  # Semi-transparent ergosphere
  ColAccretion*   = 0xF8B040FF'u32  # Hot gas glow

proc spectralColor(sc: SpectralClass): uint32 {.inline, raises: [].} =
  case sc
  of scBlueGiant:   ColStarBlue
  of scWhiteStar:   ColStarWhite
  of scYellowDwarf: ColStarYellow
  of scRedDwarf:    ColStarRed
  of scNeutronStar: ColStarCyan

proc rand32*(maxVal: float32 = 1.0f): float32 {.inline, raises: [].} =
  float32(rand(float(maxVal)))

proc rand32*(minVal: float32, maxVal: float32): float32 {.inline, raises: [].} =
  float32(rand(float(minVal) .. float(maxVal)))

proc updateRadii(sim: var BlackHoleSim) {.inline, raises: [].} =
  sim.schwarzschildR = max(12.0f, sim.mass * 3.5f)
  sim.photonR = sim.schwarzschildR * 1.5f
  sim.rocheR = sim.schwarzschildR * 2.6f

proc removeStar(sim: var BlackHoleSim, i: int) {.inline, raises: [].} =
  inc(sim.consumedCount)
  dec(sim.stars.count)
  let last = sim.stars.count
  if i < last:
    # Swap with last active star!
    sim.stars.posX[i] = sim.stars.posX[last]
    sim.stars.posY[i] = sim.stars.posY[last]
    sim.stars.velX[i] = sim.stars.velX[last]
    sim.stars.velY[i] = sim.stars.velY[last]
    sim.stars.mass[i] = sim.stars.mass[last]
    sim.stars.radius[i] = sim.stars.radius[last]
    sim.stars.color[i] = sim.stars.color[last]
    sim.stars.status[i] = sim.stars.status[last]
    sim.stars.spectral[i] = sim.stars.spectral[last]
    sim.stars.id[i] = sim.stars.id[last]
    sim.stars.trailHead[i] = sim.stars.trailHead[last]
    sim.stars.trailCount[i] = sim.stars.trailCount[last]
    let dstBase = i * MaxTrailPoints
    let srcBase = last * MaxTrailPoints
    copyMem(addr sim.stars.trailX[dstBase], addr sim.stars.trailX[srcBase], MaxTrailPoints * sizeof(float32))
    copyMem(addr sim.stars.trailY[dstBase], addr sim.stars.trailY[srcBase], MaxTrailPoints * sizeof(float32))

proc addStar*(
  sim: var BlackHoleSim,
  x, y, vx, vy: float32,
  mass, radius: float32,
  color: uint32,
  sc: uint8,
  starId: int32,
  status: uint8 = 0
): int32 {.discardable, inline, raises: [].} =
  if sim.stars.count >= MaxStars:
    return -1
  let idx = sim.stars.count
  inc(sim.stars.count)
  sim.stars.posX[idx] = x
  sim.stars.posY[idx] = y
  sim.stars.velX[idx] = vx
  sim.stars.velY[idx] = vy
  sim.stars.mass[idx] = mass
  sim.stars.radius[idx] = radius
  sim.stars.color[idx] = color
  sim.stars.status[idx] = status
  sim.stars.spectral[idx] = sc
  sim.stars.id[idx] = starId
  sim.stars.trailHead[idx] = 0
  sim.stars.trailCount[idx] = 0
  starId

proc initStar(sim: var BlackHoleSim, rMin, rMax: float32, sc: SpectralClass = scWhiteStar): int32 {.discardable, raises: [].} =
  inc(sim.nextStarId)
  let sId = int32(sim.nextStarId)
  let scCode = uint8(ord(sc))
  let col = spectralColor(sc)
  
  let theta = rand32(float32(2.0 * PI))
  let r = rMin + rand32(rMax - rMin)
  let px = sim.centerX + cos(theta) * r
  let py = sim.centerY + sin(theta) * r
  
  # Keplerian orbital velocity v = sqrt(G*M / r)
  let vMag = sqrt(sim.mass * 3800.0f / max(10.0f, r))
  let ecc = rand32(0.25f)
  let dir = if sim.spin >= 0.0f: 1.0f else: -1.0f
  let vx = -sin(theta) * vMag * dir * (1.0f + ecc)
  let vy = cos(theta) * vMag * dir * (1.0f + ecc)
  let mass = rand32(0.5f, 5.0f)
  let radius = case sc
    of scBlueGiant: 3.5f
    of scWhiteStar: 2.2f
    of scYellowDwarf: 2.0f
    of scRedDwarf: 1.6f
    of scNeutronStar: 1.2f
    
  sim.addStar(px, py, vx, vy, mass, radius, col, scCode, sId)

proc resetSimulation*(sim: var BlackHoleSim, scenarioIdx: int = 0) {.raises: [].} =
  sim.isPaused = false
  sim.simTimeSec = 0.0f
  sim.consumedCount = 0
  sim.disruptedCount = 0
  sim.selectedStarId = -1
  sim.nextStarId = 0
  sim.zoom = 1.0f
  sim.targetZoom = 1.0f
  sim.panX = 0.0f
  sim.panY = 0.0f
  sim.trailTick = 0
  sim.updateRadii()
  sim.stars.count = 0
  
  case scenarioIdx
  of 0: # Sagittarius A* (Milky Way Supermassive)
    sim.mass = 4.3f
    sim.spin = 0.82f
    sim.metric = gmKerr
    sim.updateRadii()
    for i in 0 ..< 800:
      let sc = if i mod 8 == 0: scBlueGiant elif i mod 5 == 0: scYellowDwarf elif i mod 12 == 0: scNeutronStar else: scRedDwarf
      sim.initStar(sim.photonR * 1.8f, sim.photonR * 14.0f, sc)
  of 1: # Gargantua (Accretion Supergiant)
    sim.mass = 18.0f
    sim.spin = 0.99f
    sim.metric = gmKerr
    sim.updateRadii()
    for i in 0 ..< 1200:
      let sc = if i mod 6 == 0: scBlueGiant else: scWhiteStar
      sim.initStar(sim.photonR * 1.2f, sim.photonR * 8.0f, sc)
  of 2: # Cygnus X-1 (Stellar-Mass Relativistic)
    sim.mass = 2.1f
    sim.spin = 0.95f
    sim.metric = gmSchwarzschild
    sim.updateRadii()
    for i in 0 ..< 500:
      sim.initStar(sim.photonR * 2.0f, sim.photonR * 12.0f, scYellowDwarf)
  of 3: # Tidal Disruption Event
    sim.mass = 6.0f
    sim.spin = 0.50f
    sim.metric = gmKerr
    sim.updateRadii()
    for i in 0 ..< 400:
      sim.initStar(sim.rocheR * 0.9f, sim.rocheR * 3.5f, scRedDwarf)
    for i in 0 ..< 300:
      sim.initStar(sim.photonR * 3.0f, sim.photonR * 10.0f, scWhiteStar)
  else: # Globular Cluster Infall
    sim.mass = 8.5f
    sim.spin = 0.20f
    sim.metric = gmSchwarzschild
    sim.updateRadii()
    for i in 0 ..< 1400:
      let sc = if i mod 10 == 0: scNeutronStar elif i mod 4 == 0: scYellowDwarf else: scRedDwarf
      sim.initStar(sim.photonR * 1.5f, sim.photonR * 16.0f, sc)

  # Re-init accretion particles
  sim.accretion = newSeqOfCap[AccretionParticle](MaxAccretion)
  for i in 0 ..< 220:
    let r = sim.photonR * 1.05f + rand32(sim.photonR * 2.8f)
    let angle = rand32(float32(2.0 * PI))
    let spd = sqrt(sim.mass * 3600.0f / r) * (0.9f + rand32(0.2f))
    let col = if r < sim.photonR * 1.6f: 0xF8FCFFFF'u32 # Intense white-blue inner
              elif r < sim.photonR * 2.2f: 0xFFA030FF'u32 # Orange
              else: 0xC03020CC'u32 # Deep red outer
    sim.accretion.add(AccretionParticle(
      pos: [sim.centerX + cos(angle) * r, sim.centerY + sin(angle) * r],
      vel: [-sin(angle) * spd, cos(angle) * spd],
      radius: r, angle: angle, speed: spd, life: rand32(1.0f), color: col
    ))

  # Re-init jet particles
  sim.jets = newSeqOfCap[JetParticle](MaxJet)
  for i in 0 ..< 80:
    let isUp = (i mod 2 == 0)
    let jx = sim.centerX + rand32(-4.0f, 4.0f)
    let jy = sim.centerY + (if isUp: -rand32(10.0f, 140.0f) else: rand32(10.0f, 140.0f))
    let vy = (if isUp: -rand32(250.0f, 600.0f) else: rand32(250.0f, 600.0f))
    sim.jets.add(JetParticle(
      pos: [jx, jy],
      vel: [rand32(-15.0f, 15.0f), vy],
      life: rand32(0.5f), maxLife: 0.6f + rand32(0.4f), size: 1.5f + rand32(1.5f),
      color: 0x88D8FFFF'u32
    ))

proc initBlackHoleSim*(width, height: float32): BlackHoleSim {.raises: [].} =
  result.stars = new(StarSoA)
  result.centerX = 0.0f
  result.centerY = 0.0f
  result.mass = 4.3f
  result.spin = 0.85f
  result.metric = gmKerr
  result.viscosity = 0.005f
  result.timeDilation = 1.0f
  result.showAccretion = true
  result.showPhotonSphere = true
  result.showJets = true
  result.showTidalDisrupt = true
  result.showTrails = true
  result.resetSimulation(0)

proc spawnTidalInfallStar*(sim: var BlackHoleSim): int32 {.discardable, raises: [].} =
  ## Spawns a high-mass star on an extreme parabolic infall trajectory toward the horizon
  inc(sim.nextStarId)
  let sId = int32(sim.nextStarId)
  let angle = rand32(float32(2.0 * PI))
  let dist = sim.photonR * 7.5f
  let px = sim.centerX + cos(angle) * dist
  let py = sim.centerY + sin(angle) * dist
  let vMag = sqrt(sim.mass * 3800.0f / dist) * 0.95f
  let offsetAngle = angle + float32(PI) - 0.22f
  let vx = cos(offsetAngle) * vMag
  let vy = sin(offsetAngle) * vMag
  sim.addStar(px, py, vx, vy, 12.0f, 4.5f, ColStarBlue, uint8(ord(scBlueGiant)), sId)
  result = sId

proc stepSimulation*(sim: var BlackHoleSim, dtSec: float32, onLogEvent: proc(msg: string) {.closure, gcsafe, raises: [].} = nil) {.raises: [].} =
  if sim.isPaused or dtSec <= 0.0f:
    return
    
  let dt = min(0.05f, dtSec) * sim.timeDilation
  sim.simTimeSec += dt
  sim.updateRadii()
  
  let bhX = sim.centerX
  let bhY = sim.centerY
  let gmVal = sim.mass * 3800.0f
  let rs = sim.schwarzschildR
  let rs2 = rs * rs
  let rRoche = sim.rocheR
  let rRoche2 = rRoche * rRoche
  let c2 = 45000.0f # effective speed of light squared
  let invC2 = 1.0f / c2
  let isKerr = (sim.metric == gmKerr and sim.spin != 0.0f)
  let kerrCoeff = sim.spin * gmVal * 28.0f
  let isSchwarzschild = (sim.metric != gmNewtonian)
  let hasViscosity = (sim.viscosity > 0.0f)
  let visc = sim.viscosity
  let photoZone = sim.photonR * 2.2f
  
  inc(sim.trailTick)
  let recordTrail = (sim.showTrails and (sim.trailTick and 3) == 0)
  
  # 1. Update Stars (Contiguous SoA Loop + Swap-Remove)
  var i = 0
  while i < sim.stars.count:
    let px = sim.stars.posX[i]
    let py = sim.stars.posY[i]
    let dx = px - bhX
    let dy = py - bhY
    let r2 = dx * dx + dy * dy
    
    # Event Horizon Capture (r^2 <= Rs^2) - Zero sqrt needed!
    if r2 <= rs2:
      let starId = sim.stars.id[i]
      sim.removeStar(i)
      if not onLogEvent.isNil:
        onLogEvent(&"[T+{sim.simTimeSec:.1f}s] HORIZON INFALL: Star #{starId} crossed event horizon Rs. Absorbed.")
      continue
      
    # Tidal Disruption Check (Roche limit r^2 <= rRoche^2)
    if sim.showTidalDisrupt and r2 <= rRoche2 and sim.stars.status[i] == 0:
      sim.stars.status[i] = 1 # Mark disrupted
      inc(sim.disruptedCount)
      let starId = sim.stars.id[i]
      if not onLogEvent.isNil:
        onLogEvent(&"[T+{sim.simTimeSec:.1f}s] TIDAL RUPTURE: Star #{starId} shredded by tidal forces at Roche limit.")
        
    # Gravity calculation: single sqrt!
    let r = sqrt(max(4.0f, r2))
    let invR = 1.0f / r
    let invR3 = invR / r2
    var aMag = gmVal * invR3
    
    let vx = sim.stars.velX[i]
    let vy = sim.stars.velY[i]
    
    # Relativistic General Relativity Correction (Schwarzschild Apsidal Precession)
    if isSchwarzschild:
      let l2 = dx * vy - dy * vx
      let grFactor = 1.0f + (3.0f * l2 * l2 * invC2) / r2
      aMag *= grFactor
      
    var ax = -dx * aMag
    var ay = -dy * aMag
    
    # Kerr Frame-Dragging (Lense-Thirring dragging along spin axis)
    if isKerr:
      let dragMag = kerrCoeff / max(100.0f, r2 * r)
      ax += -dy * dragMag
      ay += dx * dragMag
      
    # Viscous drag if disrupted or near accretion zone
    if hasViscosity and (sim.stars.status[i] == 1 or r < photoZone):
      let drag = visc * (if sim.stars.status[i] == 1: 4.0f else: 1.0f)
      ax -= vx * drag
      ay -= vy * drag
      
    # Euler-Verlet integration
    let newVx = vx + ax * dt
    let newVy = vy + ay * dt
    let newPx = px + newVx * dt
    let newPy = py + newVy * dt
    
    sim.stars.velX[i] = newVx
    sim.stars.velY[i] = newVy
    sim.stars.posX[i] = newPx
    sim.stars.posY[i] = newPy
    
    # Trail ring buffer update (zero allocation, O(1))
    if recordTrail:
      let head = int(sim.stars.trailHead[i])
      let base = i * MaxTrailPoints + head
      sim.stars.trailX[base] = px
      sim.stars.trailY[base] = py
      sim.stars.trailHead[i] = uint8((head + 1) mod MaxTrailPoints)
      if sim.stars.trailCount[i] < uint8(MaxTrailPoints):
        inc(sim.stars.trailCount[i])
        
    inc(i)

  # 2. Update Accretion Disk Particles
  if sim.showAccretion:
    for i in 0 ..< sim.accretion.len:
      var p = addr sim.accretion[i]
      p.speed = sqrt(gmVal / max(10.0f, p.radius)) * (if sim.spin >= 0.0f: 1.0f else: -1.0f)
      p.angle += (p.speed / max(10.0f, p.radius)) * dt * 1.5f
      # Slowly spiral in
      p.radius -= (sim.viscosity * 40.0f + 1.8f) * dt
      if p.radius < rs * 1.02f:
        # Re-inject at outer accretion boundary
        p.radius = sim.photonR * 2.8f + rand32(sim.photonR * 0.8f)
        p.angle = rand32(float32(2.0 * PI))
      p.pos[0] = bhX + cos(p.angle) * p.radius
      p.pos[1] = bhY + sin(p.angle) * p.radius * (0.35f + 0.05f * cos(p.angle)) # inclined disk perspective

  # 3. Update Relativistic Polar Jets
  if sim.showJets:
    for i in 0 ..< sim.jets.len:
      var j = addr sim.jets[i]
      j.life += dt
      j.pos[0] += j.vel[0] * dt
      j.pos[1] += j.vel[1] * dt
      if j.life >= j.maxLife:
        let isUp = (i mod 2 == 0)
        j.life = 0.0f
        j.pos[0] = bhX + rand32(-3.0f, 3.0f)
        j.pos[1] = bhY + (if isUp: -rs * 0.6f else: rs * 0.6f)
        let vy = (if isUp: -rand32(320.0f, 680.0f) else: rand32(320.0f, 680.0f))
        j.vel = [rand32(-12.0f, 12.0f), vy]
        j.vel = [rand32(-12.0f, 12.0f), vy]

# =============================================================================
# Custom Canvas Renderer (Vulkan SDF Primitives)
# =============================================================================

proc screenToWorld*(
  sim: BlackHoleSim,
  cRect: tuple[x, y, w, h: float32],
  sx, sy: float32
): tuple[wx, wy: float32] {.inline, raises: [].} =
  let viewCx = cRect.x + cRect.w * 0.5f + sim.panX
  let viewCy = cRect.y + cRect.h * 0.5f + sim.panY
  let z = max(0.1f, sim.zoom)
  (sim.centerX + (sx - viewCx) / z, sim.centerY + (sy - viewCy) / z)

proc renderBlackHoleCanvas*(
  instances: var seq[UiDrawInstance],
  sim: BlackHoleSim,
  canvasRect: tuple[x, y, w, h: float32],
  clipRect: array[4, uint16]
) {.raises: [].} =
  let (cx, cy, cw, ch) = canvasRect
  let z = max(0.1f, sim.zoom)
  let viewCx = cx + cw * 0.5f + sim.panX
  let viewCy = cy + ch * 0.5f + sim.panY
  let bhX = viewCx
  let bhY = viewCy
  let rs = sim.schwarzschildR * z
  let rph = sim.photonR * z
  let ergo = rs * (1.0f + sqrt(max(0.0f, 1.0f - sim.spin * sim.spin * 0.5f)))
  let pScale = clamp(z, 0.6f, 2.2f)
  let clipMinX = float32(clipRect[0]) - 8.0f
  let clipMinY = float32(clipRect[1]) - 8.0f
  let clipMaxX = float32(clipRect[2]) + 8.0f
  let clipMaxY = float32(clipRect[3]) + 8.0f
  
  # 1. Outer Relativistic Ergosphere boundary (Kerr frame-dragging glow)
  if sim.metric == gmKerr:
    var ergoInst: UiDrawInstance
    ergoInst.pos = [bhX - ergo, bhY - rs * 1.15f]
    ergoInst.size = [ergo * 2.0f, rs * 2.3f]
    ergoInst.uvPos = [0.0f, 0.0f]
    ergoInst.uvSize = [0.0f, 0.0f]
    ergoInst.color = 0x24243644'u32 # Subtle faint ergosphere shell
    ergoInst.borderColor = 0x4E4E6266'u32
    ergoInst.cornerRadius = rs * 1.1f
    ergoInst.borderWidth = 1.0f
    ergoInst.softness = 4.0f
    ergoInst.clipRect = clipRect
    instances.add(ergoInst)

  # 2. Relativistic Accretion Disk (Background half)
  if sim.showAccretion:
    let invRph = 1.0f / max(1.0f, sim.photonR)
    for p in sim.accretion:
      if p.pos[1] < sim.centerY: # Back of disk (world space)
        let sx = viewCx + (p.pos[0] - sim.centerX) * z
        let sy = viewCy + (p.pos[1] - sim.centerY) * z
        if sx >= clipMinX and sx <= clipMaxX and sy >= clipMinY and sy <= clipMaxY:
          var pInst: UiDrawInstance
          let pSize = (3.5f + (p.radius * invRph) * 1.2f) * pScale
          pInst.pos = [sx - pSize * 0.5f, sy - pSize * 0.5f]
          pInst.size = [pSize, pSize]
          pInst.uvPos = [0.0f, 0.0f]
          pInst.uvSize = [0.0f, 0.0f]
          pInst.color = p.color
          pInst.borderColor = 0
          pInst.cornerRadius = pSize * 0.5f
          pInst.borderWidth = 0.0f
          pInst.softness = 1.5f
          pInst.clipRect = clipRect
          instances.add(pInst)

  # 3. Relativistic Polar Jets (Beaming plasma along spin axis)
  if sim.showJets:
    for j in sim.jets:
      let sx = viewCx + (j.pos[0] - sim.centerX) * z
      let sy = viewCy + (j.pos[1] - sim.centerY) * z
      if sx >= clipMinX and sx <= clipMaxX and sy >= clipMinY and sy <= clipMaxY:
        let alphaNorm = clamp(1.0f - (j.life / j.maxLife), 0.0f, 1.0f)
        let alphaByte = uint32(alphaNorm * 220.0f) shl 24
        let jetCol = (j.color and 0x00FFFFFF'u32) or alphaByte
        let jSize = j.size * pScale
        var jInst: UiDrawInstance
        jInst.pos = [sx - jSize * 0.5f, sy - jSize * 0.5f]
        jInst.size = [jSize, jSize * 2.2f]
        jInst.uvPos = [0.0f, 0.0f]
        jInst.uvSize = [0.0f, 0.0f]
        jInst.color = jetCol
        jInst.borderColor = 0
        jInst.cornerRadius = jSize * 0.5f
        jInst.borderWidth = 0.0f
        jInst.softness = 1.5f
        jInst.clipRect = clipRect
        instances.add(jInst)

  # 4. Photon Sphere Glow Halo (r = 1.5 Rs)
  if sim.showPhotonSphere:
    var photonHalo: UiDrawInstance
    let haloSize = rph * 2.2f
    photonHalo.pos = [bhX - haloSize * 0.5f, bhY - haloSize * 0.5f]
    photonHalo.size = [haloSize, haloSize]
    photonHalo.uvPos = [0.0f, 0.0f]
    photonHalo.uvSize = [0.0f, 0.0f]
    photonHalo.color = 0x1A1A2855'u32
    photonHalo.borderColor = ColPhotonRing
    photonHalo.cornerRadius = haloSize * 0.5f
    photonHalo.borderWidth = 1.5f
    photonHalo.softness = 3.0f
    photonHalo.clipRect = clipRect
    instances.add(photonHalo)

  # 5. Singularity Event Horizon Shadow (Black Hole Interior)
  var horizonInst: UiDrawInstance
  let horizDiameter = rs * 2.0f
  horizonInst.pos = [bhX - rs, bhY - rs]
  horizonInst.size = [horizDiameter, horizDiameter]
  horizonInst.uvPos = [0.0f, 0.0f]
  horizonInst.uvSize = [0.0f, 0.0f]
  horizonInst.color = ColHorizon # Absolute black shadow
  horizonInst.borderColor = 0x2A2A38FF'u32 # Razor-sharp dark boundary
  horizonInst.cornerRadius = rs
  horizonInst.borderWidth = 1.0f
  horizonInst.softness = 1.0f
  horizonInst.clipRect = clipRect
  instances.add(horizonInst)

  # 6. Relativistic Accretion Disk (Foreground half with Doppler shift)
  if sim.showAccretion:
    let invRph = 1.0f / max(1.0f, sim.photonR)
    for p in sim.accretion:
      if p.pos[1] >= sim.centerY: # Front of disk (world space)
        let sx = viewCx + (p.pos[0] - sim.centerX) * z
        let sy = viewCy + (p.pos[1] - sim.centerY) * z
        if sx >= clipMinX and sx <= clipMaxX and sy >= clipMinY and sy <= clipMaxY:
          var pInst: UiDrawInstance
          let pSize = (3.5f + (p.radius * invRph) * 1.2f) * pScale
          pInst.pos = [sx - pSize * 0.5f, sy - pSize * 0.5f]
          pInst.size = [pSize, pSize]
          pInst.uvPos = [0.0f, 0.0f]
          pInst.uvSize = [0.0f, 0.0f]
          pInst.color = p.color
          pInst.borderColor = 0
          pInst.cornerRadius = pSize * 0.5f
          pInst.borderWidth = 0.0f
          pInst.softness = 1.5f
          pInst.clipRect = clipRect
          instances.add(pInst)

  # 7. Render Stars & Relativistic Orbital Trails
  let count = sim.stars.count
  let showTrails = sim.showTrails
  let selId = int32(sim.selectedStarId)
  
  for i in 0 ..< count:
    let wx = sim.stars.posX[i]
    let wy = sim.stars.posY[i]
    let px = viewCx + (wx - sim.centerX) * z
    let py = viewCy + (wy - sim.centerY) * z
    let sId = sim.stars.id[i]
    let isSelected = (sId == selId)
    let isDisrupted = (sim.stars.status[i] == 1)
    let sCol = if isDisrupted: 0xFF5533FF'u32 else: sim.stars.color[i]
    
    # 7a. Trails
    if showTrails:
      if isSelected or isDisrupted:
        # Full smooth ring-buffer trail for tracked or disrupted star
        let tCount = int(sim.stars.trailCount[i])
        if tCount > 1:
          let head = int(sim.stars.trailHead[i])
          let base = i * MaxTrailPoints
          for step in 0 ..< tCount - 1:
            let idx0 = (head + MaxTrailPoints - tCount + step) mod MaxTrailPoints
            let tx = viewCx + (sim.stars.trailX[base + idx0] - sim.centerX) * z
            let ty = viewCy + (sim.stars.trailY[base + idx0] - sim.centerY) * z
            if tx >= clipMinX and tx <= clipMaxX and ty >= clipMinY and ty <= clipMaxY:
              let alphaNorm = float32(step + 1) / float32(tCount)
              let alphaByte = uint32(alphaNorm * 110.0f) shl 24
              var tInst: UiDrawInstance
              tInst.pos = [tx - 1.0f, ty - 1.0f]
              tInst.size = [2.0f, 2.0f]
              tInst.uvPos = [0.0f, 0.0f]
              tInst.uvSize = [0.0f, 0.0f]
              tInst.color = (sCol and 0x00FFFFFF'u32) or alphaByte
              tInst.borderColor = 0
              tInst.cornerRadius = 1.0f
              tInst.borderWidth = 0.0f
              tInst.softness = 1.0f
              tInst.clipRect = clipRect
              instances.add(tInst)
      else:
        # High-efficiency velocity streak (single quad instance trailing behind)
        let vx = sim.stars.velX[i]
        let vy = sim.stars.velY[i]
        let v2 = vx * vx + vy * vy
        if v2 > 25.0f: # Only stars with noticeable motion
          let tx = px - vx * z * 0.022f
          let ty = py - vy * z * 0.022f
          if tx >= clipMinX and tx <= clipMaxX and ty >= clipMinY and ty <= clipMaxY:
            var tInst: UiDrawInstance
            tInst.pos = [tx - 0.75f, ty - 0.75f]
            tInst.size = [1.5f, 1.5f]
            tInst.uvPos = [0.0f, 0.0f]
            tInst.uvSize = [0.0f, 0.0f]
            tInst.color = (sCol and 0x00FFFFFF'u32) or 0x44000000'u32
            tInst.borderColor = 0
            tInst.cornerRadius = 0.75f
            tInst.borderWidth = 0.0f
            tInst.softness = 1.0f
            tInst.clipRect = clipRect
            instances.add(tInst)
          
    # 7b. Star Core
    if px >= clipMinX and px <= clipMaxX and py >= clipMinY and py <= clipMaxY:
      let sRadius = sim.stars.radius[i] * pScale
      let sW = if isDisrupted: sRadius * 3.5f else: sRadius * 2.0f
      let sH = if isDisrupted: sRadius * 1.2f else: sRadius * 2.0f
      
      var sInst: UiDrawInstance
      sInst.pos = [px - sW * 0.5f, py - sH * 0.5f]
      sInst.size = [sW, sH]
      sInst.uvPos = [0.0f, 0.0f]
      sInst.uvSize = [0.0f, 0.0f]
      sInst.color = sCol
      sInst.borderColor = if isSelected: 0x60A5FAFF'u32 else: 0'u32
      sInst.cornerRadius = min(sW, sH) * 0.5f
      sInst.borderWidth = if isSelected: 1.5f else: 0.0f
      sInst.softness = 1.2f
      sInst.clipRect = clipRect
      instances.add(sInst)

  # 8. Interactive Fling Vector Indicator (Directional dashed slingshot line)
  if sim.isFlinging:
    let fx0 = sim.flingStart[0]
    let fy0 = sim.flingStart[1]
    let fx1 = sim.flingCurrent[0]
    let fy1 = sim.flingCurrent[1]

    var anchorInst: UiDrawInstance
    anchorInst.pos = [fx0 - 5.0f, fy0 - 5.0f]
    anchorInst.size = [10.0f, 10.0f]
    anchorInst.uvPos = [0.0f, 0.0f]
    anchorInst.uvSize = [0.0f, 0.0f]
    anchorInst.color = 0x00000000'u32
    anchorInst.borderColor = 0x60A5FAFF'u32
    anchorInst.cornerRadius = 5.0f
    anchorInst.borderWidth = 1.5f
    anchorInst.softness = 1.0f
    anchorInst.clipRect = clipRect
    instances.add(anchorInst)

    for s in 1 .. 16:
      let t = float32(s) / 16.0f
      let dx = fx0 + (fx1 - fx0) * t
      let dy = fy0 + (fy1 - fy0) * t
      var dotInst: UiDrawInstance
      dotInst.pos = [dx - 1.75f, dy - 1.75f]
      dotInst.size = [3.5f, 3.5f]
      dotInst.uvPos = [0.0f, 0.0f]
      dotInst.uvSize = [0.0f, 0.0f]
      dotInst.color = 0x60A5FACC'u32
      dotInst.borderColor = 0
      dotInst.cornerRadius = 1.75f
      dotInst.borderWidth = 0.0f
      dotInst.softness = 1.0f
      dotInst.clipRect = clipRect
      instances.add(dotInst)

# =============================================================================
# Main Interactive Application
# =============================================================================

proc main() =
  var screenshotPath = ""
  let cliArgs = commandLineParams()
  var argIdx = 0
  while argIdx < cliArgs.len:
    if cliArgs[argIdx] == "--screenshot" and argIdx + 1 < cliArgs.len:
      screenshotPath = cliArgs[argIdx + 1]
      inc(argIdx, 2)
    else:
      inc(argIdx)
  let headless = screenshotPath.len > 0

  echo "================================================================="
  echo ">>> LAUNCHING NIMUI SINGULARITY LAB (BLACK HOLE & STARS) <<<"
  echo "================================================================="

  let fontAtlas = initFontAtlas("Segoe UI", 32.0f)
  var win: NativeWindow
  var backend: VulkanBackend
  if headless:
    win = NativeWindow(width: 1440, height: 880, running: false)
  else:
    win = initNativeWindow("NimUI Singularity Lab — Kerr-Schwarzschild Simulator", 1440, 880)
    var backendRes = initVulkanBackend(win.hwnd, uint32(win.width), uint32(win.height), fontAtlas)
    if not backendRes.isOk:
      echo "[FATAL] Failed to initialize Vulkan backend: ", backendRes.error
      return
    backend = backendRes.get()

  var tree = initUiTree()
  var rt = initReactiveRuntime()
  var sim = initBlackHoleSim(1440.0f, 880.0f)

  # Text Area for Astrophysical Event Log & Mission Journal
  var missionTextArea = initTextArea(
    text = "=== ASTROPHYSICAL EVENT LOG & MISSION NOTES ===\n" &
           "[T+0.0s] Kerr-Schwarzschild metric initialized.\n" &
           "[T+0.0s] Ergosphere frame-dragging online (spin a*=0.85).\n" &
           "[T+0.0s] System loaded: Sagittarius A* (4.3e6 Msun).\n" &
           "-- Notes: Select star to track. Use Ctrl+C/V for clipboard.",
    fontSize = 12.0f,
    bounds = (0.0f, 0.0f, 320.0f, 150.0f)
  )

  # Reactive Signals
  var starCountSig = rt.createSignal(sim.stars.count)
  var consumedSig = rt.createSignal(0)
  var disruptedSig = rt.createSignal(0)
  var massSig = rt.createSignal(sim.mass)
  var spinSig = rt.createSignal(sim.spin)
  var simSpeedSig = rt.createSignal(sim.timeDilation)
  var statusMsgSig = rt.createSignal("System Online — Simulating Kerr Space-Time")
  var filterTextSig = rt.createSignal("")

  # =============================================================================
  # Build Unified UI Hierarchy
  # =============================================================================

  let root = Box(
    tree,
    direction = fdColumn,
    padding = 10.0f,
    gap = 8.0f,
    width = flexGrow(),
    height = flexGrow(),
    bg = ColBgPage
  )

  # --- 1. HEADER (height 46px) ---
  let header = HStack(
    tree, root,
    padding = 8.0f,
    gap = 12.0f,
    bg = ColBgSurface,
    borderColor = ColBorder,
    radius = 10.0f,
    borderWidth = 1.0f,
    width = flexGrow(),
    height = fixed(46.0f),
    alignItems = aiCenter
  )

  let titleGroup = HStack(tree, header, gap = 8.0f, alignItems = aiCenter)
  discard Text(tree, titleGroup, "Singularity Lab", size = 16.0f, color = ColTextPrim)
  discard Text(tree, titleGroup, "/  Relativistic Kerr Engine", size = 12.0f, color = ColTextTert)

  # Forward declare onLogEventClosure for dropdown usage
  var onLogEventRef: proc(msg: string) {.closure, gcsafe, raises: [].}

  # Scenario Dropdown Component
  let scenarioItems = [
    "Sagittarius A* (Milky Way)",
    "Gargantua (Supergiant)",
    "Cygnus X-1 (Stellar)",
    "Tidal Disruption Event",
    "Globular Swarm"
  ]
  let scenarioDdId = Dropdown(
    tree, header,
    items = scenarioItems,
    selectedIndex = 0,
    width = fixed(230.0f),
    height = fixed(32.0f),
    onSelect = proc(idx: int) {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        sim.resetSimulation(idx)
        starCountSig.set(sim.stars.count)
        massSig.set(sim.mass)
        spinSig.set(sim.spin)
        statusMsgSig.set(&"Loaded Scenario: {scenarioItems[idx]}")
        if not onLogEventRef.isNil:
          onLogEventRef(&"[EVENT] Loaded scenario: {scenarioItems[idx]}")
  )
  Tooltip(tree, scenarioDdId, "Select black hole astrophysics scenario and orbital configuration", tpBelow)

  discard Box(tree, header, width = flexGrow(), height = fixed(1.0f))

  # Status Badges
  let starBadge = HStack(tree, header, padding = 4.0f, bg = ColBgRaised, borderColor = ColBorderCtl, radius = 6.0f, borderWidth = 1.0f)
  tree.nodes[starBadge].padding = [3.0f, 8.0f, 3.0f, 8.0f]
  let starBadgeText = Text(tree, starBadge, "800 Stars", size = 12.0f, color = ColTextSec)

  let massBadge = HStack(tree, header, padding = 4.0f, bg = ColBgRaised, borderColor = ColBorderCtl, radius = 6.0f, borderWidth = 1.0f)
  tree.nodes[massBadge].padding = [3.0f, 8.0f, 3.0f, 8.0f]
  let massBadgeText = Text(tree, massBadge, "4.3 M☉", size = 12.0f, color = ColTextSec)

  let fpsBadge = HStack(tree, header, padding = 4.0f, bg = ColBgRaised, borderColor = ColBorderCtl, radius = 6.0f, borderWidth = 1.0f)
  tree.nodes[fpsBadge].padding = [3.0f, 8.0f, 3.0f, 8.0f]
  let fpsBadgeText = Text(tree, fpsBadge, "60 FPS  •  0.03 ms", size = 12.0f, color = ColTextSec)

  # --- 2. MAIN CONTENT SPLIT (Columns) ---
  let mainContent = HStack(tree, root, gap = 8.0f, width = flexGrow(), height = flexGrow())

  # --- LEFT COLUMN: Controls & Parameters (width 310px) ---
  let leftCol = VStack(tree, mainContent, gap = 8.0f, width = fixed(310.0f), height = flexGrow())

  # Card 1: Metric & Physics Models
  let cardMetric = VStack(tree, leftCol, padding = 10.0f, gap = 6.0f, bg = ColBgSurface, borderColor = ColBorder, radius = 8.0f, borderWidth = 1.0f, width = flexGrow())
  discard Text(tree, cardMetric, "Gravity Metric Model", size = 13.0f, color = ColTextPrim)

  # RadioGroup Component for Metric
  let metricOptions = ["Kerr (Frame-Dragging)", "Schwarzschild (Static)", "Newtonian (Classic)"]
  let (metricContainer, metricGroup) = RadioGroup(
    tree, cardMetric,
    options = metricOptions,
    selectedIndex = 0,
    gap = 4.0f,
    onSelect = proc(idx: int, val: string) {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        case idx
        of 0: sim.metric = gmKerr
        of 1: sim.metric = gmSchwarzschild
        else: sim.metric = gmNewtonian
        statusMsgSig.set(&"Switched Metric: {val}")
  )
  Tooltip(tree, metricContainer, "Gravitational field tensor model governing orbital curvature", tpAbove)

  # Visual Feature Checkboxes
  discard Box(tree, cardMetric, width = flexGrow(), height = fixed(1.0f), bg = ColBorder)
  discard Text(tree, cardMetric, "Astrophysical Overlays", size = 13.0f, color = ColTextPrim)

  let cbAccretionId = Checkbox(tree, cardMetric, label = "Accretion Plasma Disk", checked = true, size = 16.0f, onToggle = proc(c: bool) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: sim.showAccretion = c
  )
  Tooltip(tree, cbAccretionId, "Viscous differential rotation accretion disk with Doppler beaming", tpAbove)

  let cbPhotonId = Checkbox(tree, cardMetric, label = "Photon Sphere (1.5 Rs)", checked = true, size = 16.0f, onToggle = proc(c: bool) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: sim.showPhotonSphere = c
  )
  Tooltip(tree, cbPhotonId, "Unstable circular photon orbits where light rays orbit the black hole", tpAbove)

  let cbJetsId = Checkbox(tree, cardMetric, label = "Relativistic Polar Jets", checked = true, size = 16.0f, onToggle = proc(c: bool) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: sim.showJets = c
  )
  Tooltip(tree, cbJetsId, "Blandford-Znajek relativistic plasma outflow along Kerr rotation axis", tpAbove)

  let cbTidalId = Checkbox(tree, cardMetric, label = "Tidal Disruption (Roche)", checked = true, size = 16.0f, onToggle = proc(c: bool) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: sim.showTidalDisrupt = c
  )
  Tooltip(tree, cbTidalId, "Spaghettification: stars crossing Roche limit are shredded into gas streams", tpAbove)

  let cbTrailsId = Checkbox(tree, cardMetric, label = "Orbital Velocity Trails", checked = true, size = 16.0f, onToggle = proc(c: bool) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: sim.showTrails = c
  )

  # Card 2: Singularity Sliders
  let cardSliders = VStack(tree, leftCol, padding = 10.0f, gap = 6.0f, bg = ColBgSurface, borderColor = ColBorder, radius = 8.0f, borderWidth = 1.0f, width = flexGrow())
  discard Text(tree, cardSliders, "Singularity Parameters", size = 13.0f, color = ColTextPrim)

  # Mass Slider
  let massHeader = HStack(tree, cardSliders, width = flexGrow(), alignItems = aiCenter)
  discard Text(tree, massHeader, "Mass (10^6 M☉):", size = 11.0f, color = ColTextSec)
  discard Box(tree, massHeader, width = flexGrow(), height = fixed(1.0f))
  let massValLabel = Text(tree, massHeader, "4.3", size = 11.0f, color = ColTextPrim)
  let massSliderId = Slider(tree, cardSliders, minVal = 1.0f, maxVal = 20.0f, currentVal = 4.3f, step = 0.1f, onValueChange = proc(v: float32) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sim.mass = v
      sim.updateRadii()
      massSig.set(v)
      tree.nodes[massValLabel].text = &"{v:.1f}"
  )
  Tooltip(tree, massSliderId, "Black hole mass scaling Schwarzschild radius Rs = 2GM/c^2", tpAbove)

  # Spin Parameter Slider
  let spinHeader = HStack(tree, cardSliders, width = flexGrow(), alignItems = aiCenter)
  discard Text(tree, spinHeader, "Kerr Spin a*:", size = 11.0f, color = ColTextSec)
  discard Box(tree, spinHeader, width = flexGrow(), height = fixed(1.0f))
  let spinValLabel = Text(tree, spinHeader, "0.85", size = 11.0f, color = ColTextPrim)
  let spinSliderId = Slider(tree, cardSliders, minVal = -0.99f, maxVal = 0.99f, currentVal = 0.85f, step = 0.01f, onValueChange = proc(v: float32) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sim.spin = v
      spinSig.set(v)
      tree.nodes[spinValLabel].text = &"{v:.2f}"
  )
  Tooltip(tree, spinSliderId, "Dimensionless spin a* = J/M in [-0.99, 0.99] driving ergosphere drag", tpAbove)

  # Simulation Speed Slider
  let speedHeader = HStack(tree, cardSliders, width = flexGrow(), alignItems = aiCenter)
  discard Text(tree, speedHeader, "Time Dilation:", size = 11.0f, color = ColTextSec)
  discard Box(tree, speedHeader, width = flexGrow(), height = fixed(1.0f))
  let speedValLabel = Text(tree, speedHeader, "1.0x", size = 11.0f, color = ColTextPrim)
  let speedSliderId = Slider(tree, cardSliders, minVal = 0.1f, maxVal = 4.0f, currentVal = 1.0f, step = 0.1f, onValueChange = proc(v: float32) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sim.timeDilation = v
      simSpeedSig.set(v)
      tree.nodes[speedValLabel].text = &"{v:.1f}x"
  )

  # Card 3: Interactive Action Buttons
  let cardActions = VStack(tree, leftCol, padding = 10.0f, gap = 6.0f, bg = ColBgSurface, borderColor = ColBorder, radius = 8.0f, borderWidth = 1.0f, width = flexGrow())
  discard Text(tree, cardActions, "Orbital Commands", size = 13.0f, color = ColTextPrim)

  let actRow1 = HStack(tree, cardActions, gap = 4.0f, width = flexGrow())
  discard Button(tree, actRow1, label = "+250 Stars", size = 11.0f, padding = 5.0f, bg = ColBgRaised, borderColor = ColBorderCtl, radius = 6.0f, color = ColTextPrim, onClick = proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      for k in 0 ..< 250:
        sim.initStar(sim.photonR * 1.8f, sim.photonR * 12.0f, scWhiteStar)
      starCountSig.set(sim.stars.count)
      statusMsgSig.set(&"Spawned 250 stars (Total: {sim.stars.count})")
  )
  discard Button(tree, actRow1, label = "Tidal Infall", size = 11.0f, padding = 5.0f, bg = ColBgRaised, borderColor = ColBorderCtl, radius = 6.0f, color = ColTextPrim, onClick = proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sim.spawnTidalInfallStar()
      starCountSig.set(sim.stars.count)
      statusMsgSig.set("Launched infall star on collision trajectory")
  )

  let actRow2 = HStack(tree, cardActions, gap = 4.0f, width = flexGrow())
  let pauseBtn = Button(tree, actRow2, label = "Pause", size = 11.0f, padding = 5.0f, bg = ColBgRaised, borderColor = ColBorderCtl, radius = 6.0f, color = ColTextSec, onClick = proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sim.isPaused = not sim.isPaused
      statusMsgSig.set(if sim.isPaused: "Simulation Paused" else: "Simulation Resumed")
  )
  discard Button(tree, actRow2, label = "Reset", size = 11.0f, padding = 5.0f, bg = ColBgRaised, borderColor = ColBorderCtl, radius = 6.0f, color = ColTextSec, onClick = proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sim.resetSimulation(0)
      starCountSig.set(sim.stars.count)
      statusMsgSig.set("Simulation Reset to Sgr A* default")
  )

  let actRow3 = HStack(tree, cardActions, gap = 4.0f, width = flexGrow())
  discard Button(tree, actRow3, label = "Copy Log", size = 11.0f, padding = 5.0f, bg = ColBgRaised, borderColor = ColBorderCtl, radius = 6.0f, color = ColTextSec, onClick = proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let ok = setClipboardText(missionTextArea.lines.join("\n"))
      statusMsgSig.set(if ok: "Copied mission log to clipboard" else: "Clipboard copy failed")
  )
  discard Button(tree, actRow3, label = "Paste Notes", size = 11.0f, padding = 5.0f, bg = ColBgRaised, borderColor = ColBorderCtl, radius = 6.0f, color = ColTextSec, onClick = proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let clip = getClipboardText()
      if clip.len > 0:
        let newLines = splitLogicalLines(clip)
        for ln in newLines:
          if not onLogEventRef.isNil:
            onLogEventRef("[PASTE] " & ln)
        statusMsgSig.set("Pasted text into mission notes")
  )
  discard Button(tree, actRow3, label = "Trim RAM", size = 11.0f, padding = 5.0f, bg = ColBgRaised, borderColor = ColBorderCtl, radius = 6.0f, color = ColTextSec, onClick = proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      when defined(windows):
        discard EmptyWorkingSet(GetCurrentProcess())
      statusMsgSig.set("Working set trimmed to physical minimum (~5 MB)")
  )

  # --- CENTER: Black Hole Viewport Canvas (flexGrow) ---
  let canvasBox = Box(
    tree, mainContent,
    width = flexGrow(),
    height = flexGrow(),
    bg = ColCanvasBg,
    borderColor = ColCanvasBrd,
    radius = 8.0f,
    borderWidth = 1.0f
  )

  # --- RIGHT COLUMN: Star Catalog & Mission TextArea (width 320px) ---
  let rightCol = VStack(tree, mainContent, gap = 8.0f, width = fixed(320.0f), height = flexGrow())

  # Card 1: VirtualList Star Catalog
  let cardCatalog = VStack(tree, rightCol, padding = 10.0f, gap = 6.0f, bg = ColBgSurface, borderColor = ColBorder, radius = 8.0f, borderWidth = 1.0f, width = flexGrow(), height = fixed(380.0f))
  discard Text(tree, cardCatalog, "Relativistic Star Catalog", size = 13.0f, color = ColTextPrim)

  # Search TextInput Component
  var filteredIndices = newSeqOfCap[int32](MaxStars)
  var activeFilter = ""

  let searchInput = TextInput(
    tree, cardCatalog,
    placeholder = "Search star ID or class...",
    size = 11.0f,
    width = flexGrow(),
    height = fixed(28.0f),
    onInput = proc(s: string) {.gcsafe, raises: [].} =
      {.cast(gcsafe).}: filterTextSig.set(s)
  )

  # VirtualList for 4,000+ stars
  let starListId = tree.createNode(nkVirtualList)
  let listNode = addr tree.nodes[starListId]
  listNode.virtualCount = sim.stars.count
  listNode.itemHeight = 22.0f
  listNode.widthMode = flexGrow()
  listNode.heightMode = flexGrow()
  listNode.fontSize = 11.0f
  listNode.isScrollable = true

  let invC = 1.0f / sqrt(45000.0f)
  let formatStarEntry = proc(idx: int): string {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      if idx >= 0 and idx < sim.stars.count:
        let starId = sim.stars.id[idx]
        let px = sim.stars.posX[idx]
        let py = sim.stars.posY[idx]
        let dx = px - sim.centerX
        let dy = py - sim.centerY
        let distRs = sqrt(dx*dx + dy*dy) / max(1.0f, sim.schwarzschildR)
        let vx = sim.stars.velX[idx]
        let vy = sim.stars.velY[idx]
        let velC = sqrt(vx*vx + vy*vy) * invC
        let sc = sim.stars.spectral[idx]
        let prefix = case sc
          of 0: "HD-"
          of 1: "S0-"
          of 2: "SOL-"
          of 3: "PROX-"
          else: "PSR-"
        let statStr = if sim.stars.status[idx] == 1: "RUPT" else: "Orb"
        result = &"{prefix}{starId:<5} {distRs:>4.1f}Rs  {velC:>4.2f}c [{statStr}]"
      else:
        result = ""

  let rebuildStarCatalogFilter = proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let q = activeFilter.strip()
      filteredIndices.setLen(0)
      if q.len > 0:
        for i in 0 ..< sim.stars.count:
          let prefix = case sim.stars.spectral[i]
            of 0: "hd-"
            of 1: "s0-"
            of 2: "sol-"
            of 3: "prox-"
            else: "psr-"
          let statStr = if sim.stars.status[i] == 1: "rupt" else: "orb"
          let fullTag = prefix & $sim.stars.id[i]
          if q in fullTag or q in statStr:
            filteredIndices.add(int32(i))
      if tree.nodes.contains(starListId):
        let visCount = if q.len == 0: sim.stars.count else: filteredIndices.len
        let ln = addr tree.nodes[starListId]
        ln.virtualCount = visCount
        ln.contentHeight = float32(visCount) * ln.itemHeight
        let maxScroll = max(0.0f, ln.contentHeight - ln.computedRect.h)
        if ln.scrollOffset > maxScroll:
          ln.scrollOffset = maxScroll

  listNode.renderItemProc = proc(idx: int, selected: bool): string {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let q = activeFilter.strip()
      let realIdx = if q.len == 0: idx
                    elif idx >= 0 and idx < filteredIndices.len: int(filteredIndices[idx])
                    else: -1
      result = formatStarEntry(realIdx)

  listNode.onSelect = proc(idx: int) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let q = activeFilter.strip()
      let realIdx = if q.len == 0: idx
                    elif idx >= 0 and idx < filteredIndices.len: int(filteredIndices[idx])
                    else: -1
      if realIdx >= 0 and realIdx < sim.stars.count:
        sim.selectedStarId = int(sim.stars.id[realIdx])
        let px = sim.stars.posX[realIdx]
        let py = sim.stars.posY[realIdx]
        let dx = px - sim.centerX
        let dy = py - sim.centerY
        let distRs = sqrt(dx*dx + dy*dy) / max(1.0f, sim.schwarzschildR)
        statusMsgSig.set(&"Tracking star #{sim.selectedStarId} ({distRs:.1f} Rs)")

  tree.addChild(cardCatalog, starListId)

  # Card 2: Mission Journal TextArea Component (Multiline & Clipboard)
  let cardNotes = VStack(tree, rightCol, padding = 10.0f, gap = 6.0f, bg = ColBgSurface, borderColor = ColBorder, radius = 8.0f, borderWidth = 1.0f, width = flexGrow(), height = flexGrow())
  discard Text(tree, cardNotes, "Mission Telemetry & Notes", size = 13.0f, color = ColTextPrim)
  let notesBox = Box(tree, cardNotes, width = flexGrow(), height = flexGrow(), bg = 0x101012FF'u32, borderColor = ColBorder, radius = 6.0f, borderWidth = 1.0f)

  # --- 3. FOOTER (height 30px) ---
  let footer = HStack(
    tree, root,
    padding = 5.0f,
    gap = 10.0f,
    width = flexGrow(),
    height = fixed(30.0f),
    alignItems = aiCenter
  )
  discard Text(tree, footer, "LMB: Create / Pull  •  RMB: Fling Star  •  Wheel: Zoom  •  Ctrl+C/V: Clipboard  •  Space: Pause", size = 11.0f, color = ColTextTert)
  discard Box(tree, footer, width = flexGrow(), height = fixed(1.0f))

  var htmlBindings = initHtmlBindingRegistry()
  htmlBindings.onClick("reset-camera", proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sim.panX = 0.0f
      sim.panY = 0.0f
      sim.targetZoom = 1.0f
      if sim.isPaused:
        sim.zoom = 1.0f
      statusMsgSig.set("Camera reset via Pure-Nim HTML/CSS button")
      if not onLogEventRef.isNil:
        onLogEventRef("[EVENT] Camera view reset (HTML/CSS binding)")
  )
  htmlBindings.onClick("zoom-in-camera", proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sim.targetZoom = clamp(sim.targetZoom * 1.25f, 0.35f, 3.5f)
      if sim.isPaused:
        sim.zoom = sim.targetZoom
      statusMsgSig.set(&"Zoomed in ({sim.targetZoom:.2f}x) via HTML/CSS")
      if not onLogEventRef.isNil:
        onLogEventRef(&"[EVENT] Camera zoom set to {sim.targetZoom:.2f}x (HTML/CSS)")
  )
  htmlBindings.onClick("toggle-trails", proc() {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sim.showTrails = not sim.showTrails
      let stateStr = if sim.showTrails: "ON" else: "OFF"
      statusMsgSig.set("Orbital trails: " & stateStr & " (HTML/CSS)")
      if not onLogEventRef.isNil:
        onLogEventRef("[EVENT] Orbital trails toggled " & stateStr & " (HTML/CSS)")
  )
  let footerHtmlRes = mountHtmlString(
    tree, addr rt,
    """
      <div id="html-hud-bar">
        <button id="html-reset-view" class="hud-btn" data-click="reset-camera">Reset View</button>
        <button id="html-zoom-in" class="hud-btn" data-click="zoom-in-camera">Zoom +25%</button>
        <button id="html-toggle-trails" class="hud-btn" data-click="toggle-trails">Toggle Trails</button>
      </div>
    """,
    """
      #html-hud-bar {
        display: flex;
        flex-direction: row;
        gap: 6px;
        align-items: center;
      }
      .hud-btn {
        background-color: #18181D;
        border: 1px solid #2E2E38;
        border-radius: 5px;
        padding: 2px 8px;
        color: #E2E8F0;
        font-size: 11px;
        height: 20px;
      }
      .hud-btn:hover {
        background-color: #222228;
        border-color: #666675;
      }
      .hud-btn:active {
        background-color: #2A2A33;
      }
    """,
    htmlBindings,
    footer
  )
  if footerHtmlRes.isErr():
    echo "[WARN] Failed to mount HTML/CSS footer button: ", footerHtmlRes.error()

  let footerStatusLabel = Text(tree, footer, "System Ready", size = 11.0f, color = ColTextSec)

  # =============================================================================
  # Reactive Effect Dispatches
  # =============================================================================

  discard rt.createEffect(proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let count = starCountSig.get()
      let m = massSig.get()
      let msg = statusMsgSig.get()
      activeFilter = filterTextSig.get().toLowerAscii()
      if tree.nodes.contains(starBadgeText):
        tree.nodes[starBadgeText].text = &"{count} Stars"
      if tree.nodes.contains(massBadgeText):
        tree.nodes[massBadgeText].text = &"{m:.1f} M☉"
      if tree.nodes.contains(footerStatusLabel):
        tree.nodes[footerStatusLabel].text = msg
      rebuildStarCatalogFilter()
      tree.isLayoutDirty = true
      tree.isDirty = true
  )

  # Perform Initial Layout
  tree.layoutTree(float32(win.width), float32(win.height), fontAtlas)

  # Main Loop Variables
  var lastTickTime = getMonoTime()
  var lastSecTime = getMonoTime()
  var frameCount = 0
  var currentFps = 60.0f
  var avgCpuMs = 0.025f
  var avgPhysicsMs = 0.020f
  var mouseX = 0.0f
  var mouseY = 0.0f
  var isMouseDown = false
  var isRmbDown = false
  var uiChromeCount = 0
  var lastStarCount = sim.stars.count
  var trimmedOnce = false
  var cRect = tree.nodes[canvasBox].computedRect
  var nRect = tree.nodes[notesBox].computedRect
  missionTextArea.syncWithNode(tree, notesBox, fontAtlas)
  missionTextArea.bounds = (nRect.x + 4.0f, nRect.y + 4.0f, max(100.0f, nRect.w - 8.0f), max(60.0f, nRect.h - 8.0f))

  # Log helper for event logging into mission text area (Zero full-string reallocations!)
  const MaxLogLines = 250
  let onLogEventClosure = proc(msg: string) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      if missionTextArea.lines.len >= MaxLogLines:
        missionTextArea.lines.delete(0)
      missionTextArea.lines.add(msg)
      let totalH = float32(missionTextArea.lines.len) * missionTextArea.lineHeight
      if totalH > missionTextArea.bounds.h:
        missionTextArea.scrollOffsetY = totalH - missionTextArea.bounds.h

  onLogEventRef = onLogEventClosure

  # Headless Screenshot Mode (--screenshot <path.png>)
  if headless:
    for _ in 0 ..< 24:
      sim.stepSimulation(0.016f, onLogEventClosure)
    starCountSig.set(sim.stars.count)
    tree.layoutTree(float32(win.width), float32(win.height), fontAtlas)
    cRect = tree.nodes[canvasBox].computedRect
    nRect = tree.nodes[notesBox].computedRect
    missionTextArea.syncWithNode(tree, notesBox, fontAtlas)
    missionTextArea.bounds = (nRect.x + 4.0f, nRect.y + 4.0f, max(100.0f, nRect.w - 8.0f), max(60.0f, nRect.h - 8.0f))

    discard tree.buildDrawInstances(fontAtlas)
    let canvasClip: array[4, uint16] = [
      uint16(max(0.0f, cRect.x + 1.0f)),
      uint16(max(0.0f, cRect.y + 1.0f)),
      uint16(min(float32(win.width), cRect.x + cRect.w - 1.0f)),
      uint16(min(float32(win.height), cRect.y + cRect.h - 1.0f))
    ]
    renderBlackHoleCanvas(tree.drawInstances, sim, cRect, canvasClip)
    let notesClip: array[4, uint16] = [
      uint16(max(0.0f, missionTextArea.bounds.x)),
      uint16(max(0.0f, missionTextArea.bounds.y)),
      uint16(min(float32(win.width), missionTextArea.bounds.x + missionTextArea.bounds.w)),
      uint16(min(float32(win.height), missionTextArea.bounds.y + missionTextArea.bounds.h))
    ]
    missionTextArea.emitDrawInstances(tree.drawInstances, fontAtlas, notesClip)
    renderControlOverlays(tree, fontAtlas, float32(win.width), float32(win.height))

    var fb = initSoftwareFramebuffer(int(win.width), int(win.height), ColBgPage)
    fb.renderInstancesToBuffer(tree.drawInstances, fontAtlas, clearColor = ColBgPage)
    let saved = fb.savePng(screenshotPath)
    htmlBindings.destroy()
    tree.destroy()
    rt.destroy()
    if not saved:
      echo "[ERR] Failed to write screenshot: ", screenshotPath
      quit(1)
    echo "[OK] Exported Singularity Lab screenshot: ", screenshotPath
    return

  # =============================================================================
  # Performance Logging Subsystem (nimui_profile.txt)
  # =============================================================================

  var profFile = open("nimui_profile.txt", fmWrite)
  profFile.writeLine("================================================================================")
  profFile.writeLine("  NIMUI SINGULARITY LAB — RELATIVISTIC ASTROPHYSICS TELEMETRY LOG")
  profFile.writeLine("  Started: " & now().format("yyyy-MM-dd HH:mm:ss"))
  profFile.writeLine("  Renderer: Vulkan 1.1+ SDF Direct | Controls: Checkbox, Slider, Dropdown, TextArea")
  profFile.writeLine("================================================================================")
  profFile.flushFile()

  # =============================================================================
  # Main Application Loop
  # =============================================================================

  while win.running:
    let nowTime = getMonoTime()
    let frameDt = float(inNanoseconds(nowTime - lastTickTime)) / 1_000_000_000.0
    lastTickTime = nowTime

    # 1. Dispatch Window & Input Events
    let events = win.pollEvents()

    for event in events:
      case event.kind
      of ueResize:
        backend.needsResize = true
        tree.isLayoutDirty = true
        tree.isDirty = true
      of ueMouseMove:
        mouseX = float32(event.mouseX)
        mouseY = float32(event.mouseY)
        
        # 1. Controls Dispatch (Sliders, Dropdowns)
        discard handleControlMouseMove(tree, mouseX, mouseY)
        # 2. TextArea Dispatch
        if missionTextArea.isDragging:
          missionTextArea.handleMouseMove(mouseX, mouseY, fontAtlas)
        # 3. Canvas Fling
        if isRmbDown:
          sim.flingCurrent = [mouseX, mouseY]
        # 4. Tree Dispatch
        tree.handleMouseMove(mouseX, mouseY)

      of ueMouseDown:
        mouseX = float32(event.mouseX)
        mouseY = float32(event.mouseY)
        isMouseDown = true
        
        # 1. Check Controls Overlay & Sliders (Highest Priority)
        var handled = handleControlMouseDown(tree, mouseX, mouseY)
        
        # 2. Check TextArea
        if not handled:
          let (tx, ty, tw, th) = missionTextArea.bounds
          if mouseX >= tx and mouseX <= tx + tw and mouseY >= ty and mouseY <= ty + th:
            missionTextArea.handleMouseDown(mouseX, mouseY, fontAtlas)
            missionTextArea.isFocused = true
            handled = true
          else:
            missionTextArea.isFocused = false
            
        # 3. Tree Dispatch (Buttons, VirtualList, TextInput)
        if not handled:
          tree.handleMouseDown(mouseX, mouseY)
          
        # 4. Canvas Click Interactions
        if not handled and mouseX >= cRect.x and mouseX <= cRect.x + cRect.w and mouseY >= cRect.y and mouseY <= cRect.y + cRect.h:
          let (wx, wy) = screenToWorld(sim, cRect, mouseX, mouseY)
          # Spawn a mini Keplerian star cluster at click point
          for k in 0 ..< 20:
            let offX = rand32(-15.0f, 15.0f)
            let offY = rand32(-15.0f, 15.0f)
            inc(sim.nextStarId)
            let sId = int32(sim.nextStarId)
            sim.addStar(
              wx + offX, wy + offY,
              rand32(-20.0f, 20.0f), rand32(-20.0f, 20.0f),
              2.0f, 2.0f,
              ColStarWhite, uint8(ord(scWhiteStar)), sId
            )
          starCountSig.set(sim.stars.count)

      of ueMouseUp:
        mouseX = float32(event.mouseX)
        mouseY = float32(event.mouseY)
        isMouseDown = false
        discard handleControlMouseUp(tree, mouseX, mouseY)
        if missionTextArea.isDragging:
          missionTextArea.handleMouseUp(mouseX, mouseY)
        tree.handleMouseUp(mouseX, mouseY)

      of ueRightMouseDown:
        mouseX = float32(event.mouseX)
        mouseY = float32(event.mouseY)
        isRmbDown = true
        if mouseX >= cRect.x and mouseX <= cRect.x + cRect.w and mouseY >= cRect.y and mouseY <= cRect.y + cRect.h:
          sim.isFlinging = true
          sim.flingStart = [mouseX, mouseY]
          sim.flingCurrent = [mouseX, mouseY]

      of ueRightMouseUp:
        isRmbDown = false
        if sim.isFlinging:
          sim.isFlinging = false
          # Fling new star along vector
          let (wx0, wy0) = screenToWorld(sim, cRect, sim.flingStart[0], sim.flingStart[1])
          let (wx1, wy1) = screenToWorld(sim, cRect, sim.flingCurrent[0], sim.flingCurrent[1])
          let dx = wx1 - wx0
          let dy = wy1 - wy0
          inc(sim.nextStarId)
          let sId = int32(sim.nextStarId)
          sim.addStar(
            wx0, wy0,
            -dx * 3.5f, -dy * 3.5f,
            3.0f, 2.4f,
            ColStarCyan, uint8(ord(scNeutronStar)), sId
          )
          starCountSig.set(sim.stars.count)

      of ueMouseWheel:
        # Wheel on canvas zooms simulation, on list scrolls list, on textarea scrolls notes
        let (tx, ty, tw, th) = missionTextArea.bounds
        if mouseX >= tx and mouseX <= tx + tw and mouseY >= ty and mouseY <= ty + th:
          missionTextArea.scrollOffsetY = max(0.0f, missionTextArea.scrollOffsetY - float32(event.wheelDelta) * 20.0f)
        elif mouseX >= cRect.x and mouseX <= cRect.x + cRect.w and mouseY >= cRect.y and mouseY <= cRect.y + cRect.h:
          sim.targetZoom = clamp(sim.targetZoom * pow(1.15f, float32(event.wheelDelta)), 0.35f, 3.5f)
        else:
          tree.handleMouseWheel(mouseX, mouseY, float32(event.wheelDelta) * 60.0f)

      of ueKeyDown:
        var handled = handleControlKeyDown(tree, event.keyCode)
        if not handled and missionTextArea.isFocused:
          discard missionTextArea.handleKeyDown(event.keyCode, event.ctrlDown, event.shiftDown)
          handled = true
        if not handled:
          let textInputFocused = tree.focusedNode != SlabId(-1'i32) and
                                 tree.nodes.contains(tree.focusedNode) and
                                 tree.nodes[tree.focusedNode].kind == nkTextInput
          if event.keyCode == 0x20'u32 and not textInputFocused: # VK_SPACE
            sim.isPaused = not sim.isPaused
            statusMsgSig.set(if sim.isPaused: "Simulation Paused" else: "Simulation Resumed")
          else:
            tree.handleKeyDown(event.keyCode, event.ctrlDown, event.shiftDown)

      of ueChar:
        if missionTextArea.isFocused:
          discard missionTextArea.handleChar(event.charVal)
        else:
          tree.handleChar(event.charVal)

    # Smooth exponential camera zoom interpolation
    if abs(sim.targetZoom - sim.zoom) > 0.0005f:
      let lerpAlpha = min(1.0f, float32(max(0.0, frameDt)) * 14.0f)
      sim.zoom += (sim.targetZoom - sim.zoom) * lerpAlpha

    # 2. Physics Simulation Step (Sub-millisecond SoA SIMD execution)
    let tPhysStart = getMonoTime()
    sim.stepSimulation(float32(frameDt), onLogEventClosure)
    let physTimeMs = float(inNanoseconds(getMonoTime() - tPhysStart)) / 1_000_000.0
    avgPhysicsMs = avgPhysicsMs * 0.9f + physTimeMs * 0.1f

    if sim.stars.count != lastStarCount:
      lastStarCount = sim.stars.count
      starCountSig.set(lastStarCount)

    # 3. Flush Reactive Signals & UI Layout Pass
    addr(rt).flushPendingEffects()
    if tree.isLayoutDirty or backend.needsResize:
      tree.layoutTree(float32(win.width), float32(win.height), fontAtlas)
      cRect = tree.nodes[canvasBox].computedRect
      nRect = tree.nodes[notesBox].computedRect
      missionTextArea.bounds = (nRect.x + 4.0f, nRect.y + 4.0f, max(100.0f, nRect.w - 8.0f), max(60.0f, nRect.h - 8.0f))
      tree.isLayoutDirty = false
      tree.isDirty = true

    # Automatically trim stale driver staging pages once on steady frame 25
    if not trimmedOnce and frameCount >= 25:
      when defined(windows):
        discard EmptyWorkingSet(GetCurrentProcess())
      trimmedOnce = true

    # 4. Render Frame (Cached UI Chrome + Dynamic Canvas SDF)
    let tBeforeBeginFrame = getMonoTime()
    let frameRes = backend.beginFrame(uint32(win.width), uint32(win.height))
    var cpuRenderNs = 0'i64
    if frameRes.isOk:
      let imgIndex = frameRes.get()
      let tRenderBuildStart = getMonoTime()

      # Rebuild static UI chrome only when marked dirty!
      if tree.isDirty or uiChromeCount == 0:
        discard tree.buildDrawInstances(fontAtlas)
        uiChromeCount = tree.drawInstances.len
        tree.isDirty = false
      else:
        # 4a. Instantaneous O(1) prefix restore (0 copy, 0 allocation)
        tree.drawInstances.setLen(uiChromeCount)

      # 4b. Render Black Hole & Star Physics Simulation on Canvas Viewport
      let canvasClip: array[4, uint16] = [
        uint16(max(0.0f, cRect.x + 1.0f)),
        uint16(max(0.0f, cRect.y + 1.0f)),
        uint16(min(float32(win.width), cRect.x + cRect.w - 1.0f)),
        uint16(min(float32(win.height), cRect.y + cRect.h - 1.0f))
      ]
      renderBlackHoleCanvas(tree.drawInstances, sim, cRect, canvasClip)

      # 4c. Render Mission Notes TextArea inside its card
      let notesClip: array[4, uint16] = [
        uint16(max(0.0f, missionTextArea.bounds.x)),
        uint16(max(0.0f, missionTextArea.bounds.y)),
        uint16(min(float32(win.width), missionTextArea.bounds.x + missionTextArea.bounds.w)),
        uint16(min(float32(win.height), missionTextArea.bounds.y + missionTextArea.bounds.h))
      ]
      missionTextArea.emitDrawInstances(tree.drawInstances, fontAtlas, notesClip)

      # 4d. Render Interactive Overlays (Dropdown Popups & Hover Tooltips on top)
      renderControlOverlays(tree, fontAtlas, float32(win.width), float32(win.height))

      let tBeforeRenderInstances = getMonoTime()
      cpuRenderNs = inNanoseconds(tBeforeRenderInstances - tRenderBuildStart)

      # 4e. Single Instanced Vulkan Draw Call (vkCmdDrawIndexed)
      if tree.drawInstances.len > 0:
        backend.renderInstances(imgIndex, addr tree.drawInstances[0], tree.drawInstances.len, ColBgPage)
    else:
      tree.isDirty = true
      uiChromeCount = 0

    # 5. Measure Framerate & CPU Telemetry (Excluding Vulkan VSync blocking)
    let tFrameCpuNs = inNanoseconds(tBeforeBeginFrame - nowTime) + cpuRenderNs
    let frameCpuMs = float(tFrameCpuNs) / 1_000_000.0
    avgCpuMs = avgCpuMs * 0.9f + frameCpuMs * 0.1f
    inc(frameCount)

    let secElapsed = float(inNanoseconds(nowTime - lastSecTime)) / 1_000_000_000.0
    if secElapsed >= 1.0:
      currentFps = float32(frameCount) / float32(secElapsed)
      frameCount = 0
      lastSecTime = nowTime

      let sysCpu = querySystemCpuLoad()
      let (procCpuTotal, procCpuUser, procCpuKernel) = querySelfCpuUsage(secElapsed)
      let (selfWsBytes, selfCommitBytes) = queryWorkingSetBytes()
      let selfWsMb = float32(selfWsBytes) / (1024.0f * 1024.0f)

      # Update Title & Badge
      win.setTitle(&"NimUI Singularity Lab | {currentFps:.0f} FPS | Frame: {avgCpuMs:.3f} ms | Stars: {sim.stars.count} | RAM: {selfWsMb:.1f} MB")
      if tree.nodes.contains(fpsBadgeText):
        tree.nodes[fpsBadgeText].text = &"{currentFps:.0f} FPS  •  {avgCpuMs:.3f} ms"
        tree.isLayoutDirty = true
        tree.isDirty = true

      # Telemetry log tick
      profFile.writeLine(&"[{now().format(\"yyyy-MM-dd HH:mm:ss\")}] Stars: {sim.stars.count} | FPS: {currentFps:.1f} | Frame: {avgCpuMs:.3f}ms | Phys: {avgPhysicsMs:.3f}ms | WS: {selfWsMb:.2f}MB | Consumed: {sim.consumedCount}")
      profFile.flushFile()

    # Idle wait when paused
    if sim.isPaused and not tree.isDirty and not tree.isLayoutDirty and win.running:
      win.waitEvents(16)

  # Cleanup
  htmlBindings.destroy()
  profFile.close()
  backend.destroy()
  echo "[DONE] Singularity Lab exited cleanly"

main()
