class_name PhaseMachine
extends RefCounted

const ALLOWED_COMMANDS := {
	"SURVIVOR_CHOOSE_ACTOR": ["BeginSurvivorActivation"],
	"SURVIVOR_ACTIVATION": ["MoveSurvivor", "Calm", "RemoveBlock", "RepairRadio", "BeginSearch", "UseItem", "ExchangeItems", "UseSpecialAction", "EndActivation"],
	"SURVIVOR_SEARCH_RESOLVE": ["ResolveSearchItem"],
	"SURVIVOR_DISCOVER_SELECT": ["ChooseDiscoverer"],
	"SURVIVOR_DISCOVER_RESOLVE": ["ResolveDiscover"],
	"KILLER_FAST": ["UseKillerSkill", "EndKillerFast"],
	"KILLER_MAIN": ["UseKillerSkill", "KillerMove", "KillerSearch"],
	"KILLER_SLOW": ["UseKillerSkill", "EndKillerSlow"],
	"KILLER_UNLOCK_DISCARD": ["ResolveKillerUnlockOverflow"],
	"KILLER_DRAW": [],
	"KILLER_DECK_DISCARD": [],
	"ENCOUNTER_START": [],
	"ENCOUNTER_ATTACK_SKILL": ["SelectAttackSkill", "PassAttackSkill"],
	"ENCOUNTER_DEFENDER": ["SelectDefender"],
	"ENCOUNTER_ITEM": ["SelectDefenseItem", "PassDefenseItem"],
	"ENCOUNTER_ROLL": [],
	"ENCOUNTER_FLEE": ["ConfirmFlee"],
	"DAMAGE_RESPONSE": ["ResolveDamageResponse"],
	"GAME_OVER": [],
}


func allows(phase: String, command_type: String) -> bool:
	return command_type in ALLOWED_COMMANDS.get(phase, [])


func allowed_commands(phase: String) -> Array:
	return ALLOWED_COMMANDS.get(phase, []).duplicate()
