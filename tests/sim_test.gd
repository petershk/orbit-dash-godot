extends SceneTree

# Headless policy table for the Godot Orbit Dash port.
# Protects: (1) a do-nothing ship dies ~6 s, (2) a legal-but-blind swapper does
# better than nothing yet clearly worse than (3) a lookahead bot. Asserts the
# ORDERING, not absolute scores, so tuning passes don't produce false failures.
#
# Run: Godot --headless --script tests/sim_test.gd

const DT := 1.0 / 60.0
const MAX_T := 180.0

var g

func _make():
	var s = load("res://main.gd").new()
	s._build_sfx_stub()
	s.set_geometry(1280.0, 720.0)
	s.teachSwap = false          # returning player: no tutorial grace
	s.startRun()
	return s

# ---- policies ------------------------------------------------------------
# nothing: never swaps.
func p_nothing(_s, _t) -> bool:
	return false

# mash: taps every single frame. The degenerate strategy a player finds in one
# session — it must hit the SWAP_CD denial path and must not park the ship in
# the inter-ring gap where nothing can reach it (the v37 invariant).
func p_mash(_s, _t) -> bool:
	return true

# blind: swaps on a legal cadence, same effort as the skilled policy but with
# no regard for where the debris is — the wrong-shape control.
var blind_next := 0.0
func p_blind(s, _t) -> bool:
	if s.runTime >= blind_next:
		blind_next = s.runTime + 0.25
		return true
	return false

# skilled: swap only when a lethal piece on THIS ring is about to arrive and
# the other ring is clear through the crossing.
func p_skilled(s, _t) -> bool:
	if s.runTime - s.lastSwapAt < s.SWAP_CD:
		return false
	var om: float = s.omega()
	var danger := 99.0
	for it in s.items:
		if it.type != "debris" or it.grazed:
			continue
		if int(it.ring) != int(s.ship.ring):
			continue
		var ahead: float = s.wrp(it.a - s.ship.a)
		if ahead < 0.0:
			continue
		danger = min(danger, ahead / om)
	var moon = s.moon
	if moon != null and moon.settled and int(moon.ring) == int(s.ship.ring):
		var ma: float = s.wrp(moon.a - s.ship.a)
		if ma >= 0.0:
			danger = min(danger, ma / om)
	if danger > 0.42:
		return false
	# is the other lane clear for the next ~0.9 s of travel?
	var other := 1 - int(s.ship.ring)
	for it in s.items:
		if it.type != "debris" or it.grazed or int(it.ring) != other:
			continue
		var ah: float = s.wrp(it.a - s.ship.a)
		if ah >= -0.15 and ah / om < 0.9:
			return false
	if moon != null and moon.settled and int(moon.ring) == other:
		var ma2: float = s.wrp(moon.a - s.ship.a)
		if ma2 >= -0.15 and ma2 / om < 0.9:
			return false
	return true

# ---- driver --------------------------------------------------------------
func run_policy(name: String, cb: Callable, n: int) -> Dictionary:
	var times: Array = []
	var scores: Array = []
	var denied_total := 0
	for i in n:
		blind_next = 0.0
		var s = _make()
		s.dh = 1000 + i * 7919          # a different day-seed per trial
		s.startRun()
		var t := 0.0
		var denied := 0
		while s.state == "play" and t < MAX_T:
			if cb.call(s, t):
				var before: float = s.lastSwapAt
				s.onInput()
				if s.lastSwapAt == before:
					denied += 1
			s.update(DT)
			t += DT
		times.append(s.runTime)
		scores.append(s.score)
		denied_total += denied
		s.free()
	var sum_t := 0.0
	var sum_s := 0.0
	for v in times:
		sum_t += v
	for v in scores:
		sum_s += v
	var d := {
		"name": name,
		"t": sum_t / float(n),
		"score": sum_s / float(n),
		"tmax": times.max(),
		"denied": denied_total,
	}
	print("  %-9s survival %6.2fs (max %6.2f)  score %8.1f  denied %d"
		% [name, d.t, d.tmax, d.score, d.denied])
	return d

var fails: Array = []

func check(ok: bool, msg: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + msg)
	if not ok:
		fails.append(msg)

func _init() -> void:
	print("\n== Orbit Dash (Godot) policy table, %d trials each ==" % 12)
	var nothing := run_policy("nothing", p_nothing, 12)
	var mash := run_policy("mash", p_mash, 12)
	var blind := run_policy("blind", p_blind, 12)
	var skilled := run_policy("skilled", p_skilled, 12)

	print("\n== assertions ==")
	# 1. the game can be lost by not playing, around the documented ~6 s
	check(nothing.t > 2.0 and nothing.t < 12.0,
		"do-nothing dies in 2-12s (spec says ~6s): got %.2fs" % nothing.t)
	# 2. input matters
	check(blind.t > nothing.t,
		"blind swapping beats doing nothing: %.2f > %.2f" % [blind.t, nothing.t])
	# 3. CORRECT input matters: lookahead must clearly beat same-effort blind
	check(skilled.t > blind.t * 1.5,
		"skilled beats blind by >1.5x survival: %.2f vs %.2f" % [skilled.t, blind.t])
	check(skilled.score > blind.score * 1.5,
		"skilled beats blind by >1.5x score: %.1f vs %.1f" % [skilled.score, blind.score])
	# 4. the swap cooldown is a real constraint for a masher, and mashing is not
	#    a winning strategy — it must not beat the lookahead bot.
	check(mash.denied > 0,
		"mashing hits the SWAP_CD denial path: %d denials" % mash.denied)
	check(skilled.t > mash.t * 1.5,
		"mashing does not beat skill: skilled %.2f vs mash %.2f" % [skilled.t, mash.t])
	# 5. scoring is reachable without being free
	check(nothing.score < skilled.score,
		"survival alone pays nothing: %.1f < %.1f" % [nothing.score, skilled.score])

	var m := _determinism()
	check(m, "same day-seed replays the identical spawn sequence")

	print("")
	if fails.is_empty():
		print("ALL CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % fails.size())
	quit(0 if fails.is_empty() else 1)

# determinism: two runs with the same seed, same inputs -> same item stream
func _determinism() -> bool:
	var sig := []
	for pass_i in 2:
		var s = _make()
		s.dh = 424242
		s.startRun()
		var acc := ""
		var t := 0.0
		while t < 30.0:
			if fmod(t, 0.5) < DT:
				s.onInput()
			s.update(DT)
			if s.state != "play":
				s.startRun()
			acc += "%d%s|" % [s.items.size(), str(s.score)]
			t += DT
		sig.append(acc.sha256_text())
		s.free()
	return sig[0] == sig[1]
