extends Node2D

# Orbit Dash — Godot port of games/orbit-dash/index.html (GAME_VERSION 122).
# Every formula is taken from SPEC-orbit-dash-core.md (which quotes the JS).
# Omitted on purpose: GF telemetry, ZLB leaderboard, changelog UI, attract demo.

# ---------------------------------------------------------------- constants
const SWAP_CD := 0.18
const SWAP_DENIED_FLASH := 0.22
const LETHAL_ARC := 20.0
const MOON_KILL_ARC := 26.0
const RADII_REF := [198.0, 324.0]            # 900*0.22, 900*0.36
const GUARD_REF_RADII := [79.2, 129.6]       # 360*0.22, 360*0.36
const TRAP_LOOKAHEAD := 1.2
const DEEP_ORBIT_START := 90.0
const DEEP_ORBIT_SPAN := 200.0
const DEEP_ORBIT_CAP_T := 290.0
const MOON_START := 36.0
const MOON_PERIOD := 20.0
const MOON_TRANS := 2.0
const MOON_SPEED := -0.5
const MOON_REWIND_GRACE := 1.0
const MOON_SNAP_EASE := 0.4
const WAVE_PERIOD := 30.0
const WAVE_WARN := 2.0
const WAVE_DUR := 4.0
const WAVE_CALM := 3.0
const WAVE_START := 18.0
const GRAZE_STREAK_BONUS_CAP := 8
const DOUBLE_GRAZE_WIN := 10.0
const GRAZE_IFRAME := 0.12
const PERFECT_FRAC := (30.0 - LETHAL_ARC) / (46.0 - LETHAL_ARC)
const OMEGA0 := 1.25

const MUTATORS := [
	{"key": "starshower", "name": "STAR SHOWER", "star": 0.36},
	{"key": "gemrush",    "name": "GEM RUSH",    "gem": 2.0},
	{"key": "overclock",  "name": "OVERCLOCK",   "ramp": 1.3, "graze": 4.0, "mult": 1.3},
	{"key": "noclocks",   "name": "NO CLOCKS",   "noclocks": true, "star": 0.18},
	{"key": "grazefever", "name": "GRAZE FEVER", "graze": 6.0},
	{"key": "longcombo",  "name": "COMBO FLOW",  "combo": 6.0},
	{"key": "shieldup",   "name": "SHIELD UP",   "shieldAt": 3.0},
]

# ---------------------------------------------------------------- geometry
var W := 1280.0
var H := 720.0
var cx := 640.0
var cy := 360.0
var RADII := [0.0, 0.0]
var planetR := 0.0

# ---------------------------------------------------------------- state
var state := "start"          # start | play | over
var MUT := {}
var day := ""
var dh := 0
var rng_s := 0

var ship := {"a": -PI / 2.0, "ring": 0, "r": 0.0}
var items: Array = []
var parts: Array = []
var popups: Array = []
var trail: Array = []

var score := 0
var best := 0
var runTime := 0.0
var spawnT := 0.4
var shake := 0.0
var speedLvl := 0
var flashT := 0.0
var slowT := 0.0
var combo := 0
var comboT := 0.0
var comboPeak := 1
var waveIdx := -1
var moon = null
var moonGraceUntil := -99.0
var moonRenderA := 0.0
var moonSnapT := 99.0
var shield := false
var shieldIframe := 0.0
var ringArmed := true
var snapT := 0.0
var punchT := 0.0
var swapDeniedT := 0.0
var grazeIframe := 0.0
var grazeSaveFired := false
var quickReady := true
var quickRing := -1
var lastSwapAt := -99.0
var grazeStreak := 0
var doubleGrazeT := 0.0
var waveInside := false
var waveClearT := 0.0
var firstSpawn := true
var steerUsed := false
var firstSwapAt := -1.0
var deepOrbitSeen := false
var grazeMode := false
var teachSwap := true
var overAt := 0.0
var deathCause := ""
var perfectT := 0.0
var savedT := 0.0

# ---------------------------------------------------------------- audio
var sfx := {}
var players: Array = []
var player_i := 0

# ================================================================ lifecycle
# --shots: drive the game with the lookahead policy and save PNGs, so a
# headless-ish run can produce visual proof without a human at the keyboard.
var shot_mode := false
var shot_plan := [1.5, 8.0, 20.0, 40.0]
var shot_i := 0
var shot_clock := 0.0

func _ready() -> void:
	shot_mode = OS.get_cmdline_user_args().has("--shots")
	var t := Time.get_datetime_dict_from_system(true)
	day = "%04d-%02d-%02d" % [t.year, t.month, t.day]
	dh = day_hash(day)
	MUT = MUTATORS[dh % MUTATORS.size()]
	if shot_mode:
		_build_sfx_stub()
	else:
		_build_sfx()
	_resize()
	reset()
	get_viewport().size_changed.connect(_resize)
	if shot_mode:
		DirAccess.make_dir_recursive_absolute("res://shots")
		startRun()

func _resize() -> void:
	var vs := get_viewport_rect().size
	set_geometry(vs.x, vs.y)

# Geometry without a viewport, so a headless SceneTree test can size the board.
func set_geometry(w: float, h: float) -> void:
	W = w
	H = h
	cx = W / 2.0
	cy = H / 2.0
	var m: float = min(W, H)
	RADII = [m * 0.22, m * 0.36]
	planetR = m * 0.10
	if state != "play":
		ship.r = RADII[ship.ring]

func day_hash(d: String) -> int:
	var h := 0
	for i in d.length():
		h = (h * 31 + d.unicode_at(i)) & 0xFFFFFFFF
	return h

# ---- mulberry32, uint32-faithful ----
func imul(a: int, b: int) -> int:
	a &= 0xFFFFFFFF
	b &= 0xFFFFFFFF
	var al := a & 0xFFFF
	var ah := (a >> 16) & 0xFFFF
	return ((al * b) + (((ah * b) & 0xFFFF) << 16)) & 0xFFFFFFFF

func dailyRoll() -> float:
	rng_s = (rng_s + 0x6D2B79F5) & 0xFFFFFFFF
	var s := rng_s
	var t := imul(s ^ (s >> 15), s | 1)
	t = (t ^ (t + imul(t ^ (t >> 7), t | 61))) & 0xFFFFFFFF
	return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0

func mv(key: String, dflt: float) -> float:
	return float(MUT[key]) if MUT.has(key) else dflt

# ================================================================ helpers
func wrp(a: float) -> float:
	a = fmod(a, TAU)
	if a < -PI:
		return a + TAU
	if a > PI:
		return a - TAU
	return a

func deepOrbitFrac(t: float) -> float:
	if t <= DEEP_ORBIT_START:
		return 0.0
	if t <= DEEP_ORBIT_CAP_T:
		return (t - DEEP_ORBIT_START) / DEEP_ORBIT_SPAN
	return 1.0 + log(1.0 + (t - DEEP_ORBIT_CAP_T) / 160.0)

func omegaAt(t: float) -> float:
	var ramp := mv("ramp", 1.0)
	var base: float = min(1.25 + t * 0.022 * ramp, 2.6)
	return base + deepOrbitFrac(t) * 0.7 * ramp

func omega() -> float:
	return omegaAt(runTime)

func devScale(ring: int) -> float:
	return RADII[ring] / RADII_REF[ring]

func lethalArc(ring: int) -> float:
	return LETHAL_ARC * devScale(ring)

func lethalRad(ring: int) -> float:
	return 16.0 * devScale(ring)

func grazeWindow(ring: int) -> float:
	return 46.0 * (omega() / OMEGA0) * devScale(ring)

func moonGrazeWindow(ring: int) -> float:
	return (MOON_KILL_ARC + 26.0) * (omega() / OMEGA0) * devScale(ring)

func waveState(t: float) -> String:
	if t < WAVE_START:
		return "none"
	var p := fmod(t - WAVE_START, WAVE_PERIOD)
	if p < WAVE_WARN:
		return "warn"
	if p < WAVE_WARN + WAVE_DUR:
		return "wave"
	if p < WAVE_WARN + WAVE_DUR + WAVE_CALM:
		return "calm"
	return "none"

func moonState(t: float):
	if t < MOON_START:
		return null
	var idx := int(floor((t - MOON_START) / MOON_PERIOD))
	var ring := idx % 2
	var phase := fmod(t - MOON_START, MOON_PERIOD)
	var settled := phase >= MOON_TRANS
	var fromRing: int = ring if idx == 0 else 1 - ring
	var r: float = RADII[ring] if settled else RADII[fromRing] + (RADII[ring] - RADII[fromRing]) * (phase / MOON_TRANS)
	return {
		"ring": ring, "r": r, "a": wrp(MOON_SPEED * (t - MOON_START)),
		"settled": settled, "p": 1.0 if settled else phase / MOON_TRANS,
	}

func comboWindow() -> float:
	return mv("combo", 5.0) * (1.0 + deepOrbitFrac(runTime) * 0.6)

func mult() -> int:
	return int(min(5, 1 + int(floor(float(combo) / 5.0))))

func feverOn() -> bool:
	return state == "play" and doubleGrazeT > 0.0

func award(n: int) -> int:
	var v := n * 2 if feverOn() else n
	score += v
	return v

func shipPos() -> Vector2:
	return Vector2(cx + cos(ship.a) * ship.r, cy + sin(ship.a) * ship.r)

# ================================================================ run control
func reset() -> void:
	ship = {"a": -PI / 2.0, "ring": 0, "r": RADII[0]}
	items = []
	parts = []
	popups = []
	trail = []
	score = 0
	runTime = 0.0
	spawnT = 0.4
	shake = 0.0
	speedLvl = 0
	flashT = 0.0
	slowT = 0.0
	combo = 0
	comboT = 0.0
	comboPeak = 1
	waveIdx = -1
	moon = null
	moonGraceUntil = -99.0
	moonRenderA = 0.0
	moonSnapT = 99.0
	shield = false
	shieldIframe = 0.0
	ringArmed = true
	snapT = 0.0
	punchT = 0.0
	swapDeniedT = 0.0
	grazeIframe = 0.0
	grazeSaveFired = false
	quickReady = true
	quickRing = -1
	lastSwapAt = -99.0
	grazeStreak = 0
	doubleGrazeT = 0.0
	waveInside = false
	waveClearT = 0.0
	firstSpawn = true
	steerUsed = false
	firstSwapAt = -1.0
	deepOrbitSeen = false
	perfectT = 0.0
	savedT = 0.0
	deathCause = ""

func startRun() -> void:
	reset()
	rng_s = dh
	state = "play"

func endRun(cause: String) -> void:
	state = "over"
	deathCause = cause
	overAt = float(Time.get_ticks_msec())
	shake = 14.0
	best = max(best, score)
	play("death")

# ================================================================ input
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		var k: int = e.keycode
		if k == KEY_SPACE or k == KEY_UP or k == KEY_DOWN:
			onInput()
			get_viewport().set_input_as_handled()
		elif k == KEY_G and state != "play":
			grazeMode = not grazeMode
			queue_redraw()
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		onInput()
	elif e is InputEventScreenTouch and e.pressed:
		onInput()

func onInput() -> void:
	if state == "start":
		startRun()
		return
	if state == "over":
		if float(Time.get_ticks_msec()) - overAt > 600.0:
			startRun()
		return
	if state != "play":
		return

	# --- swap cooldown / quick undo (v96) ---
	if runTime - lastSwapAt < SWAP_CD:
		if quickReady and not ringArmed:
			quickReady = false
			quickRing = 1 - int(ship.ring)
			ship.ring = quickRing
			lastSwapAt = runTime
			play("swap")
			return
		swapDeniedT = SWAP_DENIED_FLASH
		play("deny")
		return

	var wasSettled := true          # see spec: always true where read
	lastSwapAt = runTime
	var oldRing := int(ship.ring)
	ship.ring = 1 - oldRing
	ringArmed = false
	snapT = 0.0
	play("swap")
	if firstSwapAt < 0.0:
		firstSwapAt = runTime
		teachSwap = false

	var grazedThisSwap := false
	var firstGrazeA := 0.0
	var doubleGrazeItem = null

	# --- moon graze, checked before the debris loop ---
	if wasSettled and moon != null and moon.settled and int(moon.ring) == oldRing:
		var mArc: float = abs(wrp(ship.a - moon.a)) * moon.r
		var ms := devScale(int(moon.ring))
		var mgw := moonGrazeWindow(int(moon.ring))
		if mArc >= MOON_KILL_ARC * ms and mArc < mgw:
			var mClose: float = clamp((mgw - mArc) / max(1.0, mgw - MOON_KILL_ARC * ms), 0.0, 1.0)
			var gx: float = (1.0 + 3.0 * mClose) if grazeMode else 1.0
			var pts := award(int(round(mv("graze", 3.0) * gx * float(mult()))))
			pop("MOON GRAZE +%d" % pts, Color(0.72, 0.84, 1.0))
			punchT = 0.25
			grazedThisSwap = true
			firstGrazeA = moon.a
			doubleGrazeItem = moon
			grazeIframe = GRAZE_IFRAME
			grazeSaveFired = false
			play("graze")

	# --- debris graze loop ---
	for it in items:
		if not wasSettled:
			break
		if it.type != "debris" or int(it.ring) != oldRing or it.age <= 0.5 or it.grazed:
			continue
		var grazeArc: float = abs(wrp(ship.a - it.a)) * RADII[int(it.ring)]
		var gw := grazeWindow(int(it.ring))
		if grazeArc >= gw:
			continue
		var la := lethalArc(int(it.ring))

		if grazedThisSwap:
			# second piece: sandwich rule (opposite side), or moon+debris
			var ok := true
			if doubleGrazeItem != null and doubleGrazeItem.has("type"):
				ok = sign(wrp(it.a - ship.a)) != sign(wrp(firstGrazeA - ship.a))
			if ok and doubleGrazeT <= 0.0:
				it.grazed = true
				it.life = min(it.life, it.age + 1.2)
				var dp := award(int(round(5.0 * mv("mult", 1.0))))
				pop("DOUBLE GRAZE +%d" % dp, Color(1.0, 0.85, 0.35))
				doubleGrazeT = DOUBLE_GRAZE_WIN
				punchT = 0.4
				play("double")
			break

		it.grazed = true
		it.life = min(it.life, it.age + 1.2)
		grazeIframe = GRAZE_IFRAME
		grazeSaveFired = false
		var perfect := grazeArc < la + (gw - la) * PERFECT_FRAC
		var close: float = clamp((gw - grazeArc) / max(1.0, gw - la), 0.0, 1.0)
		var grazeX: float = (1.0 + 3.0 * close) if grazeMode else 1.0
		var streakBonus: int = min(grazeStreak, GRAZE_STREAK_BONUS_CAP)
		var pts2 := award(int(round((mv("graze", 3.0) + float(streakBonus)) * grazeX * float(mult()) * mv("mult", 1.0))))
		grazeStreak += 1
		if grazeMode:
			grazeCombo()
		elif comboT > 0.0:
			comboT = comboWindow()
		if perfect:
			pop("PERFECT +%d" % pts2, Color(1.0, 0.45, 0.75))
			punchT = 0.35
			perfectT = 0.5
		else:
			pop("GRAZE +%d" % pts2, Color(0.55, 1.0, 0.75))
			punchT = 0.2
		burst(itemPos(it), Color(1.0, 0.35, 0.35), 10)
		grazedThisSwap = true
		firstGrazeA = it.a
		doubleGrazeItem = it
		play("graze")

func grazeCombo() -> void:
	if not grazeMode:
		return
	combo += 1
	comboT = comboWindow()
	comboPeak = max(comboPeak, mult())
	if float(mult()) >= mv("shieldAt", 5.0) and not shield:
		shield = true
		pop("SHIELD", Color(0.5, 0.9, 1.0))

func trySpendShield() -> bool:
	if not shield or shieldIframe > 0.0:
		return false
	shield = false
	shieldIframe = 0.8
	combo = int(floor(float(combo) / 2.0))
	pop("SHIELD DOWN", Color(0.5, 0.9, 1.0))
	play("shield")
	return true

# ================================================================ spawning
func spawn() -> void:
	var r1 := dailyRoll()
	var r2 := dailyRoll()
	var r3 := dailyRoll()
	var r4 := dailyRoll()
	var r5 := dailyRoll()

	var ws := waveState(runTime)
	var deepBonus := deepOrbitFrac(runTime) * 0.11
	var debrisChance: float
	if ws == "wave":
		debrisChance = min(min(0.55 + runTime / 90.0 * 0.3, 0.85) + deepBonus, 0.95)
	elif ws == "calm":
		debrisChance = min(max(0.15, 0.35 + runTime / 90.0 * 0.3 - 0.25), 0.4)
	else:
		debrisChance = min(min(0.35 + runTime / 90.0 * 0.3, 0.65) + deepBonus, 0.95)

	var type := "debris"
	if grazeMode:
		type = "debris"
	elif firstSpawn:
		type = "gem"
	else:
		type = "debris" if r1 < debrisChance else "gem"
	firstSpawn = false

	var starChance := (2.5 if ws == "calm" else 1.0) * mv("star", 0.12)
	var comet := type == "gem" and r4 < starChance * 0.15
	var star := type == "gem" and not comet and r4 < starChance
	var noclocks: bool = MUT.has("noclocks")
	var slow := type == "gem" and not star and not comet and not noclocks and runTime > 35.0 and r5 < 0.05

	var ahead := omega() * 1.0 + 0.35 + r3 * 2.2
	var a := wrp(ship.a + ahead)

	var otherClear := true
	for it in items:
		if it.type == "debris" and int(it.ring) != int(ship.ring) and abs(wrp(it.a - a)) < 0.6:
			otherClear = false
			break
	var anyDebris := false
	for it in items:
		if it.type == "debris":
			anyDebris = true
			break
	var lessonCover := firstSwapAt >= 0.0 and runTime - firstSwapAt < 2.4 and type == "debris"
	var lessonSteer := teachSwap and not steerUsed and type == "debris" and not anyDebris and otherClear
	var ring: int
	if lessonCover:
		ring = 1 - int(ship.ring)
	elif lessonSteer:
		ring = 1 - int(ship.ring)
		steerUsed = true
	else:
		ring = 0 if r2 < 0.5 else 1

	# anti-trap guard (spawn time)
	for it in items:
		if int(it.ring) == ring and abs(wrp(it.a - a)) < 0.34:
			return
	if type == "debris":
		for it in items:
			if it.type == "debris" and int(it.ring) != ring and abs(wrp(it.a - a)) < 0.6:
				return
		var mn = moonState(runTime + ahead / max(0.1, omega()))
		if mn != null and mn.settled and int(mn.ring) != ring and abs(wrp(mn.a - a)) < 0.6:
			return

	var life: float
	if type == "gem":
		life = 4.5 if comet else (6.0 if star else (7.0 if slow else 9.0))
	else:
		life = 4.0 if ws == "wave" else 7.0
	items.append({
		"a": a, "ring": ring, "type": type, "star": star, "slow": slow,
		"comet": comet, "age": 0.0, "life": life, "grazed": false,
	})

func itemPos(it) -> Vector2:
	var r: float = RADII[int(it.ring)]
	return Vector2(cx + cos(it.a) * r, cy + sin(it.a) * r)

# ================================================================ update
func _process(dt: float) -> void:
	dt = min(dt, 0.05)
	if shot_mode:
		_shot_tick(dt)
	if state == "play":
		update(dt)
	else:
		if state == "start":
			ship.a = wrp(ship.a + 0.7 * dt)
		shake = max(0.0, shake - dt * 18.0)
		punchT = max(0.0, punchT - dt)
	for i in range(popups.size() - 1, -1, -1):
		popups[i].t -= dt
		popups[i].y -= 34.0 * dt
		if popups[i].t <= 0.0:
			popups.remove_at(i)
	for i in range(parts.size() - 1, -1, -1):
		var p = parts[i]
		p.t -= dt
		p.pos += p.vel * dt
		p.vel *= 0.94
		if p.t <= 0.0:
			parts.remove_at(i)
	queue_redraw()

func update(dt: float) -> void:
	runTime += dt
	ship.a = wrp(ship.a + omega() * dt)
	ship.r += (RADII[int(ship.ring)] - ship.r) * min(1.0, dt * 10.0)

	if not ringArmed and abs(ship.r - RADII[int(ship.ring)]) < devScale(int(ship.ring)):
		ringArmed = true
		snapT = 0.18
		if int(ship.ring) != quickRing:
			quickReady = true

	trail.push_front(shipPos())
	if trail.size() > 26:
		trail.resize(26)

	var lvl := int(floor(runTime / 15.0))
	if lvl > speedLvl:
		speedLvl = lvl
		flashT = 1.4
		play("speed")
	if not deepOrbitSeen and runTime > DEEP_ORBIT_START:
		deepOrbitSeen = true
		pop("DEEP ORBIT", Color(0.8, 0.6, 1.0))

	moon = moonState(runTime)
	if moon != null:
		moonSnapT = min(MOON_SNAP_EASE, moonSnapT + dt)
		if moonSnapT >= MOON_SNAP_EASE:
			moonRenderA = moon.a
		else:
			moonRenderA = wrp(moonRenderA + wrp(moon.a - moonRenderA) * min(1.0, dt * 10.0))

	# continuous anti-trap guard
	if moon != null and moon.settled:
		var clearNeeded := SWAP_CD * omega()
		for i in range(items.size() - 1, -1, -1):
			var it = items[i]
			if it.type != "debris" or int(it.ring) == int(moon.ring) or it.grazed:
				continue
			var gap: float = abs(wrp(it.a - moon.a)) \
				- MOON_KILL_ARC / GUARD_REF_RADII[int(moon.ring)] \
				- LETHAL_ARC / GUARD_REF_RADII[int(it.ring)]
			if gap >= clearNeeded:
				continue
			var ahead := wrp(it.a - ship.a)
			if ahead < 0.0 or ahead > TRAP_LOOKAHEAD:
				continue
			burst(itemPos(it), Color(1.0, 0.72, 0.25), 8)
			items.remove_at(i)

	# wave bookkeeping
	var ws := waveState(runTime)
	var inside := ws == "wave"
	if waveInside and not inside and comboT > 0.0:
		var wp := award(int(round(10.0 * float(mult()) * mv("mult", 1.0))))
		pop("WAVE CLEAR +%d" % wp, Color(1.0, 0.8, 0.4))
		waveClearT = 1.2
	waveInside = inside

	# spawn cadence
	spawnT -= dt
	if spawnT <= 0.0:
		spawn()
		var baseT: float = max(0.55, 1.1 - runTime * 0.008)
		spawnT = baseT * 0.55 if ws == "wave" else baseT

	# items: age, lifetime, collision
	var shieldSavedThisFrame := false
	for i in range(items.size() - 1, -1, -1):
		var it = items[i]
		it.age += dt
		if it.age >= it.life:
			items.remove_at(i)
			continue
		var ir: float = RADII[int(it.ring)]
		var arc: float = abs(wrp(ship.a - it.a)) * ir
		var rad: float = abs(ship.r - ir)
		if arc >= lethalArc(int(it.ring)) or rad >= lethalRad(int(it.ring)):
			continue

		if it.type == "gem":
			items.remove_at(i)
			combo += 1
			comboT = comboWindow()
			comboPeak = max(comboPeak, mult())
			var m := mult()
			var base: float = 15.0 if it.comet else (5.0 if it.star else (5.0 if it.slow else mv("gem", 1.0)))
			var pts := award(int(round(base * float(m) * mv("mult", 1.0))))
			if it.slow:
				var rewind: float = min(6.0, runTime)
				runTime -= rewind
				lastSwapAt -= rewind
				speedLvl = int(floor(runTime / 15.0))
				moonGraceUntil = runTime + MOON_REWIND_GRACE
				moonSnapT = 0.0
				slowT = 1.4
				pop("TIME SLOWED +%d" % pts, Color(0.6, 0.9, 1.0))
			elif it.comet:
				pop("COMET +%d" % pts, Color(0.6, 1.0, 1.0))
			elif it.star:
				pop("STAR +%d" % pts, Color(1.0, 0.9, 0.4))
			else:
				pop("+%d" % pts, Color(0.75, 1.0, 0.85))
			if float(mult()) >= mv("shieldAt", 5.0) and not shield:
				shield = true
				pop("SHIELD", Color(0.5, 0.9, 1.0))
			burst(itemPos(it), Color(0.6, 1.0, 0.8), 12)
			play("gem")
			continue

		# debris
		if firstSwapAt >= 0.0 and runTime - firstSwapAt < 2.4 and int(it.ring) == int(ship.ring):
			continue
		if it.age > 0.5 and not it.grazed:
			if trySpendShield():
				shieldSavedThisFrame = true
				burst(itemPos(it), Color(0.5, 0.9, 1.0), 14)
				items.remove_at(i)
				continue
			if grazeIframe > 0.0:
				if not grazeSaveFired:
					grazeSaveFired = true
					pop("SAVED", Color(1.0, 0.9, 0.5))
					savedT = 0.6
				continue
			endRun("debris-" + ("outer" if int(it.ring) == 1 else "inner"))
			return

	# moon collision
	if moon != null and moon.settled and runTime >= moonGraceUntil:
		var marc: float = abs(wrp(ship.a - moon.a)) * moon.r
		var mrad: float = abs(ship.r - moon.r)
		var ms := devScale(int(moon.ring))
		if marc < MOON_KILL_ARC * ms and mrad < 18.0 * ms:
			if not shieldSavedThisFrame and not trySpendShield():
				endRun("moon")
				return

	# timers
	if comboT > 0.0:
		comboT -= dt
		if comboT <= 0.0:
			combo = 0
	flashT = max(0.0, flashT - dt)
	slowT = max(0.0, slowT - dt)
	shieldIframe = max(0.0, shieldIframe - dt)
	swapDeniedT = max(0.0, swapDeniedT - dt)
	grazeIframe = max(0.0, grazeIframe - dt)
	doubleGrazeT = max(0.0, doubleGrazeT - dt)
	waveClearT = max(0.0, waveClearT - dt)
	perfectT = max(0.0, perfectT - dt)
	savedT = max(0.0, savedT - dt)
	snapT = max(0.0, snapT - dt)
	shake = max(0.0, shake - dt * 18.0)
	punchT = max(0.0, punchT - dt)

# ---------------------------------------------------------------- shot mode
func _shot_tick(dt: float) -> void:
	if state != "play":
		startRun()
		return
	# same lookahead rule the policy test uses, so the frames show real play
	if runTime - lastSwapAt >= SWAP_CD:
		var om := omega()
		var danger := 99.0
		for it in items:
			if it.type == "debris" and not it.grazed and int(it.ring) == int(ship.ring):
				var ah: float = wrp(it.a - ship.a)
				if ah >= 0.0:
					danger = min(danger, ah / om)
		if moon != null and moon.settled and int(moon.ring) == int(ship.ring):
			var ma: float = wrp(moon.a - ship.a)
			if ma >= 0.0:
				danger = min(danger, ma / om)
		if danger <= 0.42:
			var other := 1 - int(ship.ring)
			var clear := true
			for it in items:
				if it.type == "debris" and not it.grazed and int(it.ring) == other:
					var ah2: float = wrp(it.a - ship.a)
					if ah2 >= -0.15 and ah2 / om < 0.9:
						clear = false
			if moon != null and moon.settled and int(moon.ring) == other:
				var ma2: float = wrp(moon.a - ship.a)
				if ma2 >= -0.15 and ma2 / om < 0.9:
					clear = false
			if clear:
				onInput()
	shot_clock += dt
	if shot_i < shot_plan.size() and runTime >= shot_plan[shot_i]:
		shot_i += 1
		_save_shot(shot_i)
		if shot_i >= shot_plan.size():
			get_tree().quit()

func _save_shot(n: int) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shots/od_%d.png" % n)
	print("saved shots/od_%d.png  t=%.1f score=%d" % [n, runTime, score])

# ================================================================ fx
func pop(text: String, col: Color) -> void:
	var p := shipPos()
	popups.append({"text": text, "x": p.x, "y": p.y - 26.0, "t": 1.0, "col": col})

func burst(pos: Vector2, col: Color, n: int) -> void:
	for i in n:
		var ang := randf() * TAU
		var sp := 60.0 + randf() * 190.0
		parts.append({"pos": pos, "vel": Vector2(cos(ang), sin(ang)) * sp, "t": 0.45, "col": col})

# ================================================================ audio
func _build_sfx() -> void:
	sfx["swap"]   = _tone(420.0, 760.0, 0.09, "sine", 0.35)
	sfx["gem"]    = _tone(880.0, 1320.0, 0.12, "sine", 0.3)
	sfx["graze"]  = _tone(1500.0, 700.0, 0.14, "saw", 0.22)
	sfx["double"] = _tone(600.0, 1800.0, 0.22, "saw", 0.28)
	sfx["deny"]   = _tone(200.0, 150.0, 0.08, "saw", 0.3)
	sfx["shield"] = _tone(300.0, 900.0, 0.2, "sine", 0.3)
	sfx["speed"]  = _tone(500.0, 1000.0, 0.16, "sine", 0.2)
	sfx["death"]  = _tone(380.0, 60.0, 0.5, "noise", 0.4)
	for i in 8:
		var p := AudioStreamPlayer.new()
		add_child(p)
		players.append(p)

func _tone(f0: float, f1: float, dur: float, kind: String, amp: float) -> AudioStreamWAV:
	var sr := 22050
	var n := int(sr * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var ph := 0.0
	for i in n:
		var u := float(i) / float(n)
		var f: float = f0 + (f1 - f0) * u
		ph += TAU * f / float(sr)
		var env: float = pow(1.0 - u, 2.0)
		var v := 0.0
		match kind:
			"sine": v = sin(ph)
			"saw": v = fmod(ph / TAU, 1.0) * 2.0 - 1.0
			"noise": v = randf() * 2.0 - 1.0
		data.encode_s16(i * 2, int(clamp(v * env * amp * 32000.0, -32000.0, 32000.0)))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = sr
	w.stereo = false
	w.data = data
	return w

# Headless tests run the simulation with no audio and no scene tree.
func _build_sfx_stub() -> void:
	sfx = {}
	players = []

func play(key: String) -> void:
	if not sfx.has(key) or players.is_empty():
		return
	var p: AudioStreamPlayer = players[player_i]
	player_i = (player_i + 1) % players.size()
	p.stream = sfx[key]
	p.play()

# ================================================================ draw
func _draw() -> void:
	var font := ThemeDB.fallback_font
	var off := Vector2.ZERO
	if shake > 0.1:
		off = Vector2(randf_range(-shake, shake), randf_range(-shake, shake)) * 0.6
	draw_set_transform(off, 0.0, Vector2.ONE)

	# background
	draw_rect(Rect2(-off, Vector2(W, H) + Vector2(80, 80)), Color(0.035, 0.04, 0.07))
	var ws := waveState(runTime) if state == "play" else "none"
	if ws == "warn":
		draw_rect(Rect2(-off, Vector2(W, H) + Vector2(80, 80)), Color(1.0, 0.5, 0.2, 0.05))
	elif ws == "wave":
		draw_rect(Rect2(-off, Vector2(W, H) + Vector2(80, 80)), Color(1.0, 0.25, 0.2, 0.09))
	if feverOn():
		draw_rect(Rect2(-off, Vector2(W, H) + Vector2(80, 80)), Color(1.0, 0.8, 0.2, 0.05))

	var c := Vector2(cx, cy)
	# stars
	var sr := RandomNumberGenerator.new()
	sr.seed = 99
	for i in 90:
		var p := Vector2(sr.randf() * W, sr.randf() * H)
		draw_circle(p, sr.randf_range(0.6, 1.6), Color(1, 1, 1, sr.randf_range(0.1, 0.5)))

	# rings
	for r in 2:
		var active := int(ship.ring) == r
		var col := Color(0.35, 0.55, 0.85, 0.5 if active else 0.22)
		draw_arc(c, RADII[r], 0.0, TAU, 128, col, 2.0 if active else 1.0, true)

	# planet
	draw_circle(c, planetR, Color(0.14, 0.2, 0.34))
	draw_arc(c, planetR, 0.0, TAU, 64, Color(0.4, 0.6, 0.95, 0.5), 2.0, true)

	# moon
	if state == "play" and moon != null:
		var mp := Vector2(cx + cos(moonRenderA) * moon.r, cy + sin(moonRenderA) * moon.r)
		var mr := 15.0 * devScale(int(moon.ring))
		if not moon.settled:
			draw_arc(mp, mr + 10.0, 0.0, TAU, 48, Color(1.0, 0.85, 0.5, 0.8), 2.0, true)
			draw_circle(mp, mr, Color(0.75, 0.7, 0.6, 0.45))
		else:
			draw_circle(mp, mr, Color(0.82, 0.8, 0.74))
			draw_circle(mp, mr * 0.45, Color(0.6, 0.57, 0.52))
			draw_arc(mp, MOON_KILL_ARC * devScale(int(moon.ring)) * 0.55, 0.0, TAU, 48, Color(1.0, 0.4, 0.4, 0.25), 1.0, true)

	# items
	for it in items:
		var p := itemPos(it)
		var ds := devScale(int(it.ring))
		if it.type == "debris":
			var tele: float = clamp(it.age / 0.5, 0.0, 1.0)
			if it.grazed:
				draw_circle(p, 9.0 * ds, Color(0.5, 0.3, 0.3, 0.35))
				continue
			if tele < 1.0:
				draw_arc(p, (10.0 + 16.0 * (1.0 - tele)) * ds, 0.0, TAU, 32, Color(1.0, 0.4, 0.3, 0.7), 2.0, true)
			var sz := 10.0 * ds
			var pts := PackedVector2Array()
			for k in 5:
				var ang: float = it.a * 3.0 + float(k) / 5.0 * TAU
				pts.append(p + Vector2(cos(ang), sin(ang)) * sz * (1.0 if k % 2 == 0 else 0.7))
			draw_colored_polygon(pts, Color(1.0, 0.3, 0.3, 0.55 + 0.45 * tele))
		else:
			var col := Color(0.6, 1.0, 0.85)
			var sz2 := 8.0 * ds
			if it.comet:
				col = Color(0.6, 1.0, 1.0)
				sz2 = 11.0 * ds
			elif it.star:
				col = Color(1.0, 0.9, 0.4)
				sz2 = 10.0 * ds
			elif it.slow:
				col = Color(0.6, 0.85, 1.0)
				sz2 = 10.0 * ds
			var fade: float = clamp((it.life - it.age) / 1.2, 0.25, 1.0)
			col.a = fade
			var dpts := PackedVector2Array([
				p + Vector2(0, -sz2), p + Vector2(sz2 * 0.8, 0),
				p + Vector2(0, sz2), p + Vector2(-sz2 * 0.8, 0)])
			draw_colored_polygon(dpts, col)
			if it.slow:
				draw_arc(p, sz2 + 4.0, 0.0, TAU, 24, Color(0.6, 0.85, 1.0, fade * 0.8), 1.5, true)

	# trail
	for i in range(trail.size() - 1):
		var a0: float = 1.0 - float(i) / float(trail.size())
		draw_line(trail[i], trail[i + 1], Color(0.5, 0.8, 1.0, a0 * 0.35), 3.0 * a0)

	# particles
	for p in parts:
		var cc: Color = p.col
		cc.a = p.t / 0.45
		draw_circle(p.pos, 2.5 * (p.t / 0.45) + 0.6, cc)

	# ship
	var sp := shipPos()
	var scale := 1.0 + snapT * 1.2 + punchT * 0.6
	var shipCol := Color(0.6, 0.9, 1.0)
	if swapDeniedT > 0.0:
		shipCol = Color(1.0, 0.5, 0.4)
	if shieldIframe > 0.0:
		shipCol = Color(1.0, 1.0, 1.0)
	var hd: float = ship.a + PI / 2.0
	var tri := PackedVector2Array([
		sp + Vector2(cos(hd), sin(hd)) * 13.0 * scale,
		sp + Vector2(cos(hd + 2.4), sin(hd + 2.4)) * 9.0 * scale,
		sp + Vector2(cos(hd - 2.4), sin(hd - 2.4)) * 9.0 * scale])
	draw_colored_polygon(tri, shipCol)
	if shield:
		draw_arc(sp, 18.0, 0.0, TAU, 32, Color(0.5, 0.9, 1.0, 0.85), 2.0, true)
	if perfectT > 0.0:
		draw_arc(sp, 26.0 + (0.5 - perfectT) * 60.0, 0.0, TAU, 32, Color(1.0, 0.45, 0.75, perfectT * 2.0), 2.0, true)
	if savedT > 0.0:
		draw_arc(sp, 22.0, 0.0, TAU, 32, Color(1.0, 0.9, 0.5, savedT), 3.0, true)

	# popups
	for p in popups:
		var pc: Color = p.col
		pc.a = clamp(p.t, 0.0, 1.0)
		draw_string(font, Vector2(p.x - 40.0, p.y), p.text, HORIZONTAL_ALIGNMENT_CENTER, 90.0, 17, pc)

	# ---- HUD ----
	var white := Color(0.9, 0.95, 1.0)
	draw_string(font, Vector2(22, 44), str(score), HORIZONTAL_ALIGNMENT_LEFT, -1, 34, white)
	if state == "play":
		draw_string(font, Vector2(22, 70), "%.1fs" % runTime, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.6, 0.7, 0.85))
		if combo > 0:
			var mc := Color(1.0, 0.85, 0.4)
			draw_string(font, Vector2(22, 98), "x%d  combo %d" % [mult(), combo], HORIZONTAL_ALIGNMENT_LEFT, -1, 17, mc)
			var bw: float = 120.0 * clamp(comboT / comboWindow(), 0.0, 1.0)
			draw_rect(Rect2(22, 106, bw, 4), mc)
		if grazeStreak > 0:
			draw_string(font, Vector2(22, 130), "graze streak %d" % grazeStreak, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.55, 1.0, 0.75))
		if feverOn():
			draw_string(font, Vector2(W - 190, 44), "FEVER x2  %.1f" % doubleGrazeT, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1.0, 0.85, 0.35))
		if ws == "warn":
			draw_string(font, Vector2(cx - 70, 56), "WAVE INCOMING", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1.0, 0.65, 0.3))
		elif ws == "wave":
			draw_string(font, Vector2(cx - 40, 56), "WAVE", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1.0, 0.35, 0.3))
		if flashT > 0.0:
			draw_string(font, Vector2(cx - 55, H - 40), "SPEED UP", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0.7, 0.85, 1.0, min(1.0, flashT)))

	draw_string(font, Vector2(W - 260, H - 24), "%s · %s" % [MUT.name, "DODGE ONLY" if grazeMode else "CLASSIC"],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.5, 0.6, 0.78))

	if state == "start":
		_panel(font, "ORBIT DASH", [
			"tap / click / SPACE — swap ring",
			"collect gems, graze the red debris",
			"a graze pays more the closer it was",
			"[G] mode: %s" % ("DODGE ONLY" if grazeMode else "CLASSIC"),
			"",
			"today: %s — %s" % [day, MUT.name],
			"tap to launch",
		])
	elif state == "over":
		_panel(font, "%d" % score, [
			"best %d  ·  %.1fs  ·  peak x%d" % [best, runTime, comboPeak],
			"lost to %s" % deathCause,
			"",
			"tap to run again",
		])

func _panel(font: Font, title: String, lines: Array) -> void:
	var w := 460.0
	var h := 64.0 + lines.size() * 26.0
	var r := Rect2(cx - w / 2.0, cy - h / 2.0, w, h)
	draw_rect(r, Color(0.05, 0.06, 0.1, 0.88))
	draw_rect(r, Color(0.4, 0.6, 0.9, 0.35), false, 2.0)
	draw_string(font, Vector2(r.position.x, r.position.y + 46), title, HORIZONTAL_ALIGNMENT_CENTER, w, 34, Color(0.9, 0.96, 1.0))
	var y := r.position.y + 80.0
	for l in lines:
		draw_string(font, Vector2(r.position.x, y), l, HORIZONTAL_ALIGNMENT_CENTER, w, 16, Color(0.68, 0.78, 0.92))
		y += 26.0
