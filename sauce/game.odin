#+feature dynamic-literals
package main

/*

This is the file where you actually make the game.

It will grow pretty phat. This is where the magic happens.

GAMEPLAY O'CLOCK !

*/

import "bald:input"
import "bald:draw"
import "bald:sound"
import "bald:utils"
import "bald:utils/color"
import bald_user "bald-user"

import "core:log"
import "core:fmt"
import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

import "core:strings"
import "core:strconv"

import sapp "bald:sokol/app"
import spall "core:prof/spall"

VERSION :string: "v0.0.0"
WINDOW_TITLE :: "pixel detective"
GAME_RES_WIDTH :: 1280//480
GAME_RES_HEIGHT :: 720//270
TILE_WIDTH :: 65
TILE_HEIGHT :: 35
window_w := 1280
window_h := 720
map_path := "./tiled/map0.tmj"
starting_y : f32 = 16 * 5

game_state_name := Game_State_Name.game

DEBUG_HINTS := false
DEBUG_PATHFIND := true

DEBUG_ENTITY : ^Entity = nil

CONSOLE_COMMAND := false
CONSOLE_TEXT := ""

when NOT_RELEASE {
	// can edit stuff in here to be whatever for testing
	PROFILE :: false
} else {
	// then this makes sure we've got the right settings for release
	PROFILE :: false
}

//
// epic game state

Game_State :: struct {
	ticks: u64,
	game_time_elapsed: f64,
	cam_pos: Vec2, // this is used by the renderer

	// entity system
	entity_top_count: int,
	latest_entity_id: int,
	entities: [MAX_ENTITIES]Entity,
	entity_free_list: [dynamic]int,

	// hints
	hints: [dynamic]bald_user.hint_ui,
	hint_text: string,
	force_hint_text: string,

	// player
	player_handle: Entity_Handle,
	player_cell: int,
	player_cell_x: int,
	player_cell_y: int,

	// world
	all_cells: [TILE_WIDTH * TILE_HEIGHT]bool,
	all_cells_entity: [TILE_WIDTH * TILE_HEIGHT]^Entity,
	all_doors: [dynamic]^Entity,
	all_interest_points: [dynamic]^Entity,

	// time
	time_hour: int,
	time_minute: int,
	tick_to_minute: f64,
	day: int,
	month: bald_user.Month,
	year: int,

	// location
	current_district: string,
	current_block: string,

	// actions
	last_actions: [dynamic]string,
	current_lockpick: ^Entity,
	current_weapon: ^Entity,
	current_target: ^Entity,

	// Widget
	dialog_text: [dynamic]string,
	bottom_buttons: [dynamic]bald_user.button_ui,

	// quests
	all_quests: [dynamic]bald_user.Quest,
	quest_available: [dynamic]bald_user.Quest,
	selecting_quest: bool,
	current_quest: bald_user.Quest,

	scratch: struct {
		all_entities: []Entity_Handle,
	}
}

//
// action -> key mapping

action_map: map[Input_Action]input.Key_Code = {
	.left = .A,
	.right = .D,
	.up = .W,
	.down = .S,
	.click = .LEFT_MOUSE,
	.use = .RIGHT_MOUSE,
	.interact = .E,
}

Input_Action :: enum u8 {
	left,
	right,
	up,
	down,
	click,
	use,
	interact,
}

Game_State_Name :: enum u8 {
	main_menu,
	game
}

//
// entity system

Entity :: struct {
	handle: Entity_Handle,
	kind: Entity_Kind,

	// todo, move this into static entity data
	update_proc: proc(^Entity),
	draw_proc: proc(Entity),

	// big sloppy entity state dump.
	// add whatever you need in here.
	pos: Vec2,
	last_known_x_dir: f32,
	flip_x: bool,
	draw_offset: Vec2,
	draw_pivot: Pivot,
	rotation: f32,
	hit_flash: Vec4,
	sprite: Sprite_Name,
	anim_index: int,
 	next_frame_end_time: f64,
  	loop: bool,
  	frame_duration: f32,
	name: string,

	can_move: bool,
	time_to_move: f32,
	in_discussion: bool,

	max_health: f32,
	current_health: f32,

	child_entity: ^Entity,
	parent_entity: ^Entity,

	x: int,
	y: int,

	enemy: bool,
	movement_total: int,
	last_movement: Input_Action,

	// door
	door_state: bald_user.Door_State,
	door_level: bald_user.Door_Level,
	unlocked: bool,
	attributed: bool,
	building_index: int,

	// tile
	special_tile: bool,
	on_trigger_tile: bool,
	can_be_interact_with: bool,

	// stats
	vitality: int,
	chance: int,
	lockpick: int,
	hack: int,
	endurance: int,
	power: int,
	charisma: int,
	intelligence: int,

	// damage
	damage_low: int,
	damage_high: int,
	
	// inventory
	inventory: [dynamic]^Entity,

	// item
	value_min: int,
	value_max: int,

	// ai
	path: [dynamic]^Entity,
	move_to_path: bool,
	path_index: int,

	// this gets zeroed every frame. Useful for passing data to other systems.
	scratch: struct {
		col_override: Vec4,
	}
}

Entity_Kind :: enum {
	nil,
	player,
	thing1,
	ai,
	wall,
	dot,
	door,
	stairs_up,
	restaurant,
	police,
	work_selection,

	//items
	lockpick,
	baton,
}

entity_setup :: proc(e: ^Entity, kind: Entity_Kind) {
	// entity defaults
	e.draw_proc = draw_entity_default
	e.draw_pivot = .bottom_center

	switch kind {
		case .nil:
		case .player: setup_player(e)
		case .thing1: setup_thing1(e)
		case .ai: setup_ai(e)
		case .wall: setup_wall(e)
		case .dot: setup_dot(e)
		case .door: setup_door(e)
		case .stairs_up: setup_stairs_up(e)
		case .lockpick: setup_lockpick(e)
		case .baton: setup_baton(e)
		case .restaurant: setup_restaurant(e)
		case .police: setup_police(e)
		case .work_selection: setup_work_selection(e)
	}
}

//
// main game procs

app_init :: proc() {
}

app_frame :: proc() {

	// right now we are just calling the game update, but in future this is where you'd do a big
	// "UX" switch for startup splash, main menu, settings, in-game, etc
	switch game_state_name {
		case .main_menu: {
			main_menu_ui()

			main_menu_update()
		}
		case .game: {
			game_ui()

			sound.play_continuously("event:/ambiance", "")

			game_update()
			game_draw()

			volume :f32= 0.75
			sound.update(get_player().pos, volume)
		}
	}
}

app_shutdown :: proc() {
	// called on exit

}

main_menu_ui :: proc() {
	draw.push_coord_space(get_screen_space())

	screen_x, screen_y := screen_pivot(.top_center)
	draw.draw_text({screen_x, screen_y - 20}, "PIXEL DETECTIVE", z_layer=.ui, pivot=Pivot.top_center, scale=5)

	draw.draw_text({screen_x, screen_y - 500}, "Press any key", z_layer=.ui, pivot=Pivot.top_center, scale=2)
}

game_ui :: proc() {
	// ui space example
	draw.push_coord_space(get_screen_space())

	screen_x, screen_y := screen_pivot(.top_left)

	// HP
	player := get_player()
	buf: [4]byte
	result := strconv.itoa(buf[:], int(player.current_health))
	str := string(result)
	hp_string : string =  strings.concatenate({"HP : ", str})
	draw.draw_text({screen_x + 2, screen_y - 20}, hp_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.damage_low))
	str = string(result)
	buf_high: [4]byte
	result_high := strconv.itoa(buf_high[:], int(player.damage_high))
	str_high := string(result_high)
	dmg_string : string =  strings.concatenate({"dmg : ", str, " - ", str_high})
	draw.draw_text({screen_x + 100, screen_y - 20}, dmg_string, z_layer=.ui, pivot=Pivot.top_left)


	// STATS
	result = strconv.itoa(buf[:], int(player.vitality))
	str = string(result)
	vitality_string : string = strings.concatenate({"Vit : ", str})
	draw.draw_text({screen_x + 100, screen_y - 2}, vitality_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.chance))
	str = string(result)
	chance_string : string =  strings.concatenate({"Chan : ", str})
	draw.draw_text({screen_x + 200, screen_y - 2}, chance_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.endurance))
	str = string(result)
	endurance_string : string =  strings.concatenate({"End : ", str})
	draw.draw_text({screen_x + 300, screen_y - 2}, endurance_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.lockpick))
	str = string(result)
	lockpick_string : string =  strings.concatenate({"Lock : ", str})
	draw.draw_text({screen_x + 2, screen_y - 2}, lockpick_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.hack))
	str = string(result)
	hack_string : string =  strings.concatenate({"Hack : ", str})
	draw.draw_text({screen_x + 400, screen_y - 2}, hack_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.power))
	str = string(result)
	power_string : string =  strings.concatenate({"Pow : ", str})
	draw.draw_text({screen_x + 500, screen_y - 2}, power_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.charisma))
	str = string(result)
	charisma_string : string =  strings.concatenate({"Char : ", str})
	draw.draw_text({screen_x + 600, screen_y - 2}, charisma_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.intelligence))
	str = string(result)
	intelligence_string : string =  strings.concatenate({"Int : ", str})
	draw.draw_text({screen_x + 700, screen_y - 2}, intelligence_string, z_layer=.ui, pivot=Pivot.top_left)

	// ACTIONS
	screen_x, screen_y = screen_pivot(.top_right)
	action_it := 0
	if len(ctx.gs.last_actions) > 37 {
		action_it = len(ctx.gs.last_actions) - 37
	}
	y := 0
	for action_it_index := action_it; action_it_index < len(ctx.gs.last_actions); action_it_index += 1 {
		draw.draw_text({screen_x - 238, screen_y - 80 - f32(y * 15)}, ctx.gs.last_actions[action_it_index], z_layer=.ui, pivot=Pivot.top_left, scale= 0.85)
		y += 1
	}

	// DATE
	screen_x, screen_y = screen_pivot(.top_right)
	result_day := strconv.itoa(buf[:], int(ctx.gs.day))
	str = string(result_day)
	buf2: [4]byte
	result_year := strconv.itoa(buf2[:], int(ctx.gs.year))
	str2 := string(result_year)
	date_string : string =  strings.concatenate({str, " ", bald_user.month_to_string(ctx.gs.month), " ", str2})
	draw.draw_text({screen_x - 220, screen_y - 2}, date_string, z_layer=.ui, pivot=Pivot.top_left)

	// TIME
	result_hour := strconv.itoa(buf[:], int(ctx.gs.time_hour))
	str = string(result_hour)
	hour_text_single := (ctx.gs.time_hour < 10 ? "0" : "")
	result_minute := strconv.itoa(buf2[:], int(ctx.gs.time_minute))
	str2 = string(result_minute)
	minute_text_single := (ctx.gs.time_minute < 10 ? "0" : "")
	time_hour_string := strings.concatenate({"Time : ", hour_text_single, str, "h", minute_text_single, str2})
	draw.draw_text({screen_x - 100, screen_y - 2}, time_hour_string, z_layer=.ui, pivot=Pivot.top_left)

	// LOCATION
	location_string : string =  strings.concatenate({ctx.gs.current_district, " - ", ctx.gs.current_block})
	draw.draw_text({screen_x - 220, screen_y - 20}, location_string, z_layer=.ui, pivot=Pivot.top_left)

	// HINT
	screen_x, screen_y = screen_pivot(.top_left)
	draw.draw_text({screen_x + 2, screen_y - 50}, ctx.gs.hint_text, z_layer=.ui, pivot=Pivot.top_left)

	if DEBUG_HINTS {
		for hint in ctx.gs.hints {
			xform := Matrix4(1)
			xform *= utils.xform_translate(hint.pos - Vec2({-8, 15}))
			
			draw.draw_rect_xform(xform, hint.size, col=Vec4{0,1,0,0.8}, z_layer=.ui)
		}
	}

	// TARGET
	screen_x, screen_y = screen_pivot(.top_right)
	if ctx.gs.current_target != nil {
		result_hp := strconv.itoa(buf[:], int(ctx.gs.current_target.current_health))
		str = string(result_hp)
		target_string : string =  strings.concatenate({"target : ", ctx.gs.current_target.name, " (", result_hp, "HP)"})
		draw.draw_text({screen_x - 400, screen_y - 650}, target_string, z_layer=.ui, pivot=Pivot.top_left)
	}

	// DEBUG_ENTITY
	screen_x, screen_y = screen_pivot(.top_right)
	if DEBUG_ENTITY != nil {
		target_string : string =  strings.concatenate({"DEBUG : ", DEBUG_ENTITY.name})
		draw.draw_text({screen_x - 400, screen_y - 700}, target_string, z_layer=.ui, pivot=Pivot.top_left)

		// DEBUG_PATHFIND
		if DEBUG_PATHFIND {
			for tile in DEBUG_ENTITY.path {
				screen_x, screen_y = screen_pivot(.bottom_left)
				xform := Matrix4(1)
				xform *= utils.xform_translate(tile.pos + Vec2{4, 0})
					
				draw.draw_rect_xform(xform, Vec2({8, 8}), col=Vec4{0,1,0,1})
			}
		}
	}

	// CONSOLE
	if CONSOLE_COMMAND {
		screen_x, screen_y = screen_pivot(.bottom_left)
		xform := Matrix4(1)
		xform *= utils.xform_translate(Vec2({0, 0}))
			
		draw.draw_rect_xform(xform, Vec2({f32(window_w), 20}), col=Vec4{0.2,0.2,0.2,1}, z_layer=.ui)
		draw.draw_text({screen_x + 2, screen_y + 15}, CONSOLE_TEXT, z_layer=.ui, pivot=Pivot.top_left)
	}

	// TALK
	if get_player().in_discussion {
		screen_x, screen_y = screen_pivot(.top_center)
		xform := Matrix4(1)
		xform *= utils.xform_translate(Vec2({640 - 250, 720 / 2 - 250}))

		draw.draw_rect_xform(xform, Vec2({500, 500}), col=color.BLACK, z_layer=.ui)
		
		if ctx.gs.selecting_quest {
			draw.draw_text({screen_x + 2 - 250, 720 / 2 + 100}, "Select case :", z_layer=.ui, pivot=Pivot.top_left)
			i := 1
			for quest in ctx.gs.quest_available {
				result_index := strconv.itoa(buf[:], i)
				str = string(result_index)
				draw.draw_text({screen_x + 2 - 250, 720 / 2 + 100 - f32(i * 20)}, strings.concatenate({str, " - ", quest.name}), z_layer=.ui, pivot=Pivot.top_left)
				i += 1
			}
			draw.draw_text({screen_x + 2 - 250, 720 / 2 + 100 - f32(i * 20)}, "Press E to close", z_layer=.ui, pivot=Pivot.top_left)
			
		}
		else {
			i := 0
			for text in ctx.gs.dialog_text {
				draw.draw_text({screen_x + 2 - 250, 720 / 2 + 80 - f32(i * 20)}, text, z_layer=.ui, pivot=Pivot.top_left)
				i += 1
			}
		}
	}

	// BUTTONS
	for button in ctx.gs.bottom_buttons {
		screen_x, screen_y = screen_pivot(.bottom_left)
		xform := Matrix4(1)
		xform *= utils.xform_translate(button.pos)

		draw.draw_rect_xform(xform, button.size, col=button.color, z_layer=.ui)
		draw.draw_text(button.pos + Vec2{10, button.size.y / 2 - 5}, button.text, z_layer=.ui, pivot=Pivot.bottom_left)
	}
}

main_menu_init :: proc() {

}

game_init :: proc() {
	utils.load_player_prefs()

	ctx.gs.time_hour = 9
	ctx.gs.time_minute = 0

	ctx.gs.day = 14
	ctx.gs.month = bald_user.Month.April
	ctx.gs.year = 2067

	ctx.gs.current_district = "District 1"
	ctx.gs.current_block = "Block NW"

	ctx.gs.player_cell_x = 1
	ctx.gs.player_cell_y = 1
	ctx.gs.player_cell = ctx.gs.player_cell_y * TILE_WIDTH + ctx.gs.player_cell_x

	q: bald_user.Quest
	q.name = "quest test"
	q.current_step = 0
	append(&q.steps, bald_user.Quest_Step({"step0", "a step 0"}))
	append(&ctx.gs.all_quests, q)

	map_info := utils.map_from_file(map_path)

	copied_array : [dynamic]int
	for copied_y := (TILE_HEIGHT - 1); copied_y >= 0; copied_y -= 1 {
		for copied_x := 0; copied_x < TILE_WIDTH; copied_x += 1 {
			append(&copied_array, map_info.layers[0].data[copied_y * TILE_WIDTH + copied_x])
		}
	}

	i := 0
	for id in copied_array {
		p : ^Entity = nil
		if id == 25 {
			p1 := entity_create(.ai)
			p = entity_create(.dot)
			ctx.gs.all_cells[i] = false
			ctx.gs.all_cells_entity[i] = p
			p.child_entity = p1
			p1.parent_entity = p
			p.can_be_interact_with = true
		}
		else if id == 844 {
			p = entity_create(.wall)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 894 {
			p = entity_create(.wall)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 880 {
			p = entity_create(.dot)
			ctx.gs.all_cells[i] = false
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 177 {
			p = entity_create(.ai)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
			p.sprite = .player_tile2
		}
		else if id == 450 {
			p = entity_create(.door)
			ctx.gs.all_cells[i] = false
			ctx.gs.all_cells_entity[i] = p
			p.door_state = bald_user.Door_State.Open
			append(&ctx.gs.all_doors, p)
		}
		else if id == 447 {
			p = entity_create(.door)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
			p.door_state = bald_user.Door_State.Locked
			p.sprite = .door_closed
			append(&ctx.gs.all_doors, p)
		}
		else if id == 448 {
			p = entity_create(.door)
			ctx.gs.all_cells[i] = false
			ctx.gs.all_cells_entity[i] = p
			p.door_state = bald_user.Door_State.Open
			append(&ctx.gs.all_doors, p)
		}
		else if id == 320 {
			p = entity_create(.ai)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
			p.sprite = .player_tile3
		}
		else if id == 224 {
			p = entity_create(.ai)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
			p.sprite = .player_tile4
		}
		else if id == 173 {
			p = entity_create(.ai)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
			p.sprite = .player_tile5
		}
		else if id == 297 {
			p = entity_create(.stairs_up)
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 947 {
			p = entity_create(.restaurant)
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 897 {
			p = entity_create(.police)
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 493 {
			p = entity_create(.work_selection)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
		}
		else {
			ctx.gs.all_cells[i] = false
			ctx.gs.all_cells_entity[i] = nil
		}

		if p != nil {
			x := i % TILE_WIDTH
			y := (i - x) / TILE_WIDTH
			p.pos = Vec2{f32(x * 16), starting_y + f32(y * 16)}
			p.x = x
			p.y = y
			if p.child_entity != nil {
				p.child_entity.pos = p.pos
				p.child_entity.x = x
				p.child_entity.y = y
			}
		}

		i += 1
	}

	building_num := 1
	for door in ctx.gs.all_doors
	{
		if ctx.gs.all_cells_entity[(door.y + 1) * TILE_WIDTH + door.x + 1].kind == .police {
			door.attributed = true
		}
		else if ctx.gs.all_cells_entity[(door.y - 1) * TILE_WIDTH + door.x + 1].kind == .police {
			door.attributed = true
		}
		else if ctx.gs.all_cells_entity[(door.y + 1) * TILE_WIDTH + door.x - 1].kind == .police {
			door.attributed = true
		}
		else if ctx.gs.all_cells_entity[(door.y - 1) * TILE_WIDTH + door.x - 1].kind == .police {
			door.attributed = true
		}
		else if ctx.gs.all_cells_entity[(door.y + 1) * TILE_WIDTH + door.x + 1].kind == .restaurant {
			door.attributed = true
		}
		else if ctx.gs.all_cells_entity[(door.y - 1) * TILE_WIDTH + door.x + 1].kind == .restaurant {
			door.attributed = true
		}
		else if ctx.gs.all_cells_entity[(door.y + 1) * TILE_WIDTH + door.x - 1].kind == .restaurant {
			door.attributed = true
		}
		else if ctx.gs.all_cells_entity[(door.y - 1) * TILE_WIDTH + door.x - 1].kind == .restaurant {
			door.attributed = true
		}
		else {
			door.attributed = true
			door.building_index = building_num
			building_num += 1
		}
	}

	player := entity_create(.player)
	ctx.gs.player_handle = player.handle
	player.pos = Vec2{16, starting_y + 16}

	// init items
	lockpick := entity_create(.lockpick)
	ctx.gs.current_lockpick = lockpick
	append(&player.inventory, lockpick)

	baton := entity_create(.baton)
	ctx.gs.current_weapon = baton
	append(&player.inventory, baton)

	// hints
	init_hints()

	// intro
	get_player().in_discussion = true
	append(&ctx.gs.dialog_text, "Hello inspector, welcome to town !")
	append(&ctx.gs.dialog_text, "a case is waiting for you on the board")
	append(&ctx.gs.dialog_text, "")
	append(&ctx.gs.dialog_text, "")
	append(&ctx.gs.dialog_text, "note : the game encourage you to take note with a pen and a paper")
	append(&ctx.gs.dialog_text, "")
	append(&ctx.gs.dialog_text, "Press E to close")

	// buttons
	inventory_button := bald_user.button_ui({})
	inventory_button.pos = Vec2{0, 0}
	inventory_button.size = Vec2{100, 30}
	inventory_button.text = "Inventory"
	inventory_button.color = Vec4{0.2, 0.2, 0.2, 1}
	append(&ctx.gs.bottom_buttons, inventory_button)
}

init_hints :: proc() {
	hint := bald_user.hint_ui({})
	hint.pos = Vec2({0, f32(window_h)})
	hint.size = Vec2({50, 15})
	hint.text = "Lockpick"
	append(&ctx.gs.hints, hint)

	hint = bald_user.hint_ui({})
	hint.pos = Vec2({90, f32(window_h)})
	hint.size = Vec2({50, 15})
	hint.text = "Vitality"
	append(&ctx.gs.hints, hint)

	hint = bald_user.hint_ui({})
	hint.pos = Vec2({190, f32(window_h)})
	hint.size = Vec2({50, 15})
	hint.text = "Chance"
	append(&ctx.gs.hints, hint)

	hint = bald_user.hint_ui({})
	hint.pos = Vec2({290, f32(window_h)})
	hint.size = Vec2({50, 15})
	hint.text = "Endurance"
	append(&ctx.gs.hints, hint)

	hint = bald_user.hint_ui({})
	hint.pos = Vec2({390, f32(window_h)})
	hint.size = Vec2({50, 15})
	hint.text = "Hack"
	append(&ctx.gs.hints, hint)

	hint = bald_user.hint_ui({})
	hint.pos = Vec2({490, f32(window_h)})
	hint.size = Vec2({50, 15})
	hint.text = "Power"
	append(&ctx.gs.hints, hint)

	hint = bald_user.hint_ui({})
	hint.pos = Vec2({590, f32(window_h)})
	hint.size = Vec2({50, 15})
	hint.text = "Charisma"
	append(&ctx.gs.hints, hint)

	hint = bald_user.hint_ui({})
	hint.pos = Vec2({690, f32(window_h)})
	hint.size = Vec2({50, 15})
	hint.text = "Intelligence"
	append(&ctx.gs.hints, hint)

	hint = bald_user.hint_ui({})
	hint.pos = Vec2({0, f32(window_h) - 20})
	hint.size = Vec2({50, 15})
	hint.text = "Health Points"
	append(&ctx.gs.hints, hint)

	hint = bald_user.hint_ui({})
	hint.pos = Vec2({90, f32(window_h) - 20})
	hint.size = Vec2({50, 15})
	hint.text = "Damage"
	append(&ctx.gs.hints, hint)
}

main_menu_update :: proc(){
	ctx.gs.scratch = {} // auto-zero scratch for each update

	// this'll be using the last frame's camera position, but it's fine for most things
	draw.push_coord_space(get_world_space())

	// setup world for first game tick
	if ctx.gs.ticks == 0 {
		main_menu_init()
	}

	rebuild_scratch_helpers()

	if input.key_pressed(.ESC) {
		sapp.request_quit()
		return
	}
	if input.any_key_press_and_consume() {
		game_state_name = Game_State_Name.game
		ctx.gs.ticks = 0
		return
	}

	ctx.gs.game_time_elapsed += f64(ctx.delta_t)
	ctx.gs.ticks += 1
}

game_update :: proc() {
	ctx.gs.scratch = {} // auto-zero scratch for each update
	defer {
		// update at the end
		ctx.gs.game_time_elapsed += f64(ctx.delta_t)
		ctx.gs.ticks += 1
	}

	// this'll be using the last frame's camera position, but it's fine for most things
	draw.push_coord_space(get_world_space())

	// setup world for first game tick
	if ctx.gs.ticks == 0 {
		game_init()
	}

	rebuild_scratch_helpers()

	ctx.gs.force_hint_text = ""
	// big :update time
	for handle in get_all_ents() {
		e := entity_from_handle(handle)

		update_entity_animation(e)

		if e.update_proc != nil {
			e.update_proc(e)
		}
	}

	if input.key_pressed(.LEFT_MOUSE) {
		input.consume_key_pressed(.LEFT_MOUSE)

		pos := mouse_pos_in_current_space()
		log.info("schloop at", pos)
		sound.play("event:/schloop", pos=pos)

		// BUTTONS
		for button in ctx.gs.bottom_buttons {
			if pos.x > button.pos.x && pos.x < button.pos.x + button.size.x && pos.y > button.pos.y && pos.y < button.pos.y + button.size.y {
				log.info("inventory")
			}
		}
	}
	if input.key_pressed(.F1) {
		DEBUG_HINTS = !DEBUG_HINTS
	}
	if input.key_pressed(.F10) {
		CONSOLE_COMMAND = !CONSOLE_COMMAND
	}
	if CONSOLE_COMMAND {
		if input.key_pressed(.ENTER) {
			analyse_command(CONSOLE_TEXT)
			CONSOLE_COMMAND = false
			CONSOLE_TEXT = ""
		}
		else if input.key_pressed(.BACKSPACE) {
			CONSOLE_TEXT = strings.cut(CONSOLE_TEXT, 0, len(CONSOLE_TEXT) - 1)
		}
		else {
			the_key := input.any_key_pressed()
			CONSOLE_TEXT = strings.concatenate({CONSOLE_TEXT, input.key_code_to_string(the_key)})
		}
	}
	if input.key_pressed(.ESC) {
		sapp.request_quit()
	}

	utils.animate_to_target_v2(&ctx.gs.cam_pos, get_player().pos, ctx.delta_t, rate=10)

	ctx.gs.hint_text = ctx.gs.force_hint_text
	for hint in ctx.gs.hints {
		pos := mouse_pos_in_current_space()
		if pos.x >= hint.pos.x && pos.x <= hint.pos.x + hint.size.x &&
			pos.y <= hint.pos.y && pos.y >= hint.pos.y - hint.size.y {
			ctx.gs.hint_text = hint.text
		}
	}

	// ... add whatever other systems you need here to make epic game
}

rebuild_scratch_helpers :: proc() {
	// construct the list of all entities on the temp allocator
	// that way it's easier to loop over later on
	all_ents := make([dynamic]Entity_Handle, 0, len(ctx.gs.entities), allocator=context.temp_allocator)
	for &e in ctx.gs.entities {
		if !is_valid(e) do continue
		append(&all_ents, e.handle)
	}
	ctx.gs.scratch.all_entities = all_ents[:]
}

game_draw :: proc() {
	// this is so we can get the current pixel in the shader in world space (VERYYY useful)
	draw.draw_frame.ndc_to_world_xform = get_world_space_camera() * linalg.inverse(get_world_space_proj())
	//draw.draw_frame.bg_repeat_tex0_atlas_uv = draw.atlas_uv_from_sprite(.bg_repeat_tex0)

	ctx.gs.cam_pos = Vec2{632, 360}

	// background thing
	{
		// identity matrices, so we're in clip space
		draw.push_coord_space({proj=Matrix4(1), camera=Matrix4(1)})

		// draw rect that covers the whole screen
		//draw.draw_rect(Rect{ -1, -1, 1, 1}, flags=.background_pixels) // we leave it in the hands of the shader
	}

	// world
	{
		draw.push_coord_space(get_world_space())
		
		//draw.draw_sprite({10, 10}, .player_still, col_override=Vec4{1,0,0,0.4})
		//draw.draw_sprite({-10, 10}, .player_still)

		//draw.draw_text({0, -50}, "sugon", pivot=.bottom_center, col={0,0,0,0.1})

		for handle in get_all_ents() {
			e := entity_from_handle(handle)
			e.draw_proc(e^)
		}
	}
}

// note, this needs to be in the game layer because it varies from game to game.
// Specifically, stuff like anim_index and whatnot aren't guarenteed to be named the same or actually even be on the base entity.
// (in terrafactor, it's inside a sub state struct)
draw_entity_default :: proc(e: Entity) {
	e := e // need this bc we can't take a reference from a procedure parameter directly

	if e.sprite == nil {
		return
	}

	xform := utils.xform_rotate(e.rotation)

	draw_sprite_entity(&e, e.pos, e.sprite, xform=xform, anim_index=e.anim_index, draw_offset=e.draw_offset, flip_x=e.flip_x, pivot=e.draw_pivot)
}

// helper for drawing a sprite that's based on an entity.
// useful for systems-based draw overrides, like having the concept of a hit_flash across all entities
draw_sprite_entity :: proc(
	entity: ^Entity,

	pos: Vec2,
	sprite: Sprite_Name,
	pivot:=utils.Pivot.center_center,
	flip_x:=false,
	draw_offset:=Vec2{},
	xform:=Matrix4(1),
	anim_index:=0,
	col:=color.WHITE,
	col_override:Vec4={},
	z_layer:ZLayer={},
	flags:Quad_Flags={},
	params:Vec4={},
	crop_top:f32=0.0,
	crop_left:f32=0.0,
	crop_bottom:f32=0.0,
	crop_right:f32=0.0,
	z_layer_queue:=-1,
) {

	col_override := col_override

	col_override = entity.scratch.col_override
	if entity.hit_flash.a != 0 {
		col_override.xyz = entity.hit_flash.xyz
		col_override.a = max(col_override.a, entity.hit_flash.a)
	}

	draw.draw_sprite(pos, sprite, pivot, flip_x, draw_offset, xform, anim_index, col, col_override, z_layer, flags, params, crop_top, crop_left, crop_bottom, crop_right)
}

//
// ~ Gameplay Slop Waterline ~
//
// From here on out, it's gameplay slop time.
// Structure beyond this point just slows things down.
//
// No point trying to make things 'reusable' for future projects.
// It's trivially easy to just copy and paste when needed.
//

// shorthand for getting the player
get_player :: proc() -> ^Entity {
	return entity_from_handle(ctx.gs.player_handle)
}

// SETUP

setup_player :: proc(e: ^Entity) {
	e.kind = .player

	// this offset is to take it from the bottom center of the aseprite document
	// and center it at the feet
	e.draw_offset = Vec2{0.5, 5}
	e.draw_pivot = .bottom_center

	e.max_health = 100
	e.current_health = e.max_health

	e.vitality = 5
	e.chance = 5
	e.lockpick = 5
	e.hack = 5
	e.endurance = 5
	e.power = 5
	e.charisma = 5
	e.intelligence = 5
	e.damage_low = 1
	e.damage_high = 3

	e.update_proc = proc(e: ^Entity) {

		if CONSOLE_COMMAND {
			return
		}

		if get_player().in_discussion {
			if ctx.gs.selecting_quest {
				if input.key_pressed(._1) && len(ctx.gs.quest_available) > 0 {
					ctx.gs.current_quest = ctx.gs.quest_available[0]
					append(&ctx.gs.last_actions, strings.concatenate({"Started quest : ", ctx.gs.current_quest.name}))
					append(&ctx.gs.last_actions, strings.concatenate({"A note was added to your inventory"}))
					get_player().in_discussion = false
					ctx.gs.selecting_quest = false
					return
				}
			}

			if is_action_pressed(.interact) {
				get_player().in_discussion = false
			}
			return
		}

		if e.can_move == false {
			e.time_to_move -= ctx.delta_t
			if e.time_to_move <= 0 {
				e.time_to_move = 0
				e.can_move = true	
			}
		}
		else {
			input_dir := get_input_vector()
			moved : bool = false
			if input_dir.x != 0 {
				input_dir.y = 0
				input_dir.x = input_dir.x > 0 ? 1 : -1
				if (input_dir.x < 0 && ctx.gs.player_cell_x > 0) || (input_dir.x > 0 && ctx.gs.player_cell_x < TILE_WIDTH - 1) {
					if ctx.gs.all_cells[ctx.gs.player_cell + int(input_dir.x)] == false {
						e.pos += input_dir * 16.0
						ctx.gs.player_cell += int(input_dir.x)
						ctx.gs.player_cell_x += int(input_dir.x)
						moved = true
						if ctx.gs.all_cells_entity[ctx.gs.player_cell].on_trigger_tile == true {
							// to do : change floor 
						}
					}
				}
			}
			else if input_dir.y != 0 {
				input_dir.x = 0
				input_dir.y = input_dir.y > 0 ? 1 : -1
				if (input_dir.y < 0 && ctx.gs.player_cell_y > 0) || (input_dir.y > 0 && ctx.gs.player_cell_y < TILE_HEIGHT - 1) {
					if ctx.gs.all_cells[ctx.gs.player_cell + int(input_dir.y) * TILE_WIDTH] == false {
						e.pos += input_dir * 16.0
						ctx.gs.player_cell += int(input_dir.y) * TILE_WIDTH
						ctx.gs.player_cell_y += int(input_dir.y)
						moved = true
						if ctx.gs.all_cells_entity[ctx.gs.player_cell].on_trigger_tile == true {
							log.debug("lol")
						}
					}
				}
			}
	
			if input_dir.x != 0 {
				e.last_known_x_dir = input_dir.x
			}
	
			e.flip_x = e.last_known_x_dir < 0
	
			if input_dir == {} {
				entity_set_animation(e, .player_idle, 0.3)
			} else {
				entity_set_animation(e, .player_run, 0.1)
				if moved {
					e.can_move = false
					e.time_to_move = 0.1
					move_time()
				}
			}
		}

		if is_action_pressed(.interact) {
			if ctx.gs.player_cell_x > 0 {
				//left
				index := ctx.gs.player_cell_y * TILE_WIDTH + ctx.gs.player_cell_x - 1
				cell := check_cell(index)
				if cell != nil{
					interact_with_cell(e, cell, index)
				}
			}
			if ctx.gs.player_cell_x < TILE_WIDTH - 1 {
				//right
				index := ctx.gs.player_cell_y * TILE_WIDTH + ctx.gs.player_cell_x + 1
				cell := check_cell(index)
				if cell != nil{
					interact_with_cell(e, cell, index)
				}
			}
			if ctx.gs.player_cell_y > 0 {
				//bottom
				index := (ctx.gs.player_cell_y - 1) * TILE_WIDTH + ctx.gs.player_cell_x
				cell := check_cell(index)
				if cell != nil{
					interact_with_cell(e, cell, index)
				}
			}
			if ctx.gs.player_cell_y < TILE_HEIGHT - 1 {
				//top
				index := (ctx.gs.player_cell_y + 1) * TILE_WIDTH + ctx.gs.player_cell_x
				cell := check_cell(index)
				if cell != nil{
					interact_with_cell(e, cell, index)
				}
			}
		}

		e.scratch.col_override = Vec4{0,0,1,0.2}
	}

	e.draw_proc = proc(e: Entity) {
		draw.draw_sprite(e.pos, .shadow_medium, col={1,1,1,0.2})
		draw_entity_default(e)
	}
}

interact_with_cell :: proc(e: ^Entity, cell: ^Entity, index: int) {
	if cell.kind == .door && cell.door_state == bald_user.Door_State.Locked {
		if e.lockpick < int(cell.door_level) * 25 {
			append(&ctx.gs.last_actions, strings.concatenate({"not enough skill (", bald_user.door_level_to_string(cell.door_level), ")"}))
			return
		} 
		if ctx.gs.current_lockpick == nil {
			append(&ctx.gs.last_actions, strings.concatenate({cell.name, " is locked (", bald_user.door_level_to_string(cell.door_level), ")"}))
			append(&ctx.gs.last_actions, strings.concatenate({"you don't have any lockpick"}))
		}
		else {
			chance : f32 = f32(e.chance) / 100
			success :i32 = 50 + i32(chance) * 100
			random := rand.int31_max(101)
			if success >= random {
				append(&ctx.gs.last_actions, strings.concatenate({"lockpicked : ", cell.name, " (", bald_user.door_level_to_string(cell.door_level), ")"}))
				cell.door_state = bald_user.Door_State.Open
				cell.sprite = .door
				if e.lockpick < 100 {
					e.lockpick += 1
				}
				ctx.gs.all_cells[index] = false
				cell.unlocked = true
			}
			else {
				append(&ctx.gs.last_actions, strings.concatenate({"fail to lockpick : ", cell.name, " (", bald_user.door_level_to_string(cell.door_level), ")"}))
				if ctx.gs.current_lockpick != nil {
					ctx.gs.current_lockpick.current_health -= 20
					buf: [4]byte
					result := strconv.itoa(buf[:], int(ctx.gs.current_lockpick.current_health))
					str := string(result)
					append(&ctx.gs.last_actions, strings.concatenate({"lockpick health is ", str}))
					if ctx.gs.current_lockpick.current_health <= 0 {
						append(&ctx.gs.last_actions, strings.concatenate({"lockpick broke"}))
						ctx.gs.current_lockpick = nil
					}
				}
			}
		}
	}
	else if cell.kind == .ai || cell.kind == .dot && cell.child_entity.kind == .ai {
		tile := (cell.kind == .dot ? cell.child_entity : cell)
		if tile.enemy == true { // ATTACK
			ctx.gs.current_target = tile
			random := rand.int31_max(20) // 0 fail critical, 19 success critical, rest ok
			multiply := 1
			multiply_text := ""
			if random == 0 {
				multiply_text = "(critical fail)"
				multiply = 0
			}
			else if random == 19 {
				multiply_text = "(critical success)"
				multiply = 2
			}
			chance : f64 = f64(e.chance) / 100
			max : f64 = (100 /f64(3)) + chance * (100 * (2 / f64(3)))
			rest := (100 - max) / 2

			final_rand := rand.float64_range(0, 100)
			buf: [4]byte
			if final_rand <= max {
				result := strconv.itoa(buf[:], e.damage_high * multiply)
				str := string(result)
				append(&ctx.gs.last_actions, strings.concatenate({"you deal ", str, " damage ", multiply_text}))
				tile.current_health -= f32(e.damage_high * multiply)
			}
			else if final_rand <= max + rest {
				result := strconv.itoa(buf[:], (e.damage_high - e.damage_low) * multiply)
				str := string(result)
				append(&ctx.gs.last_actions, strings.concatenate({"you deal ", str, " damage ", multiply_text}))
				tile.current_health -= f32((e.damage_high - e.damage_low) * multiply)
			}
			else {
				result := strconv.itoa(buf[:], e.damage_low * multiply)
				str := string(result)
				append(&ctx.gs.last_actions, strings.concatenate({"you deal ", str, " damage ", multiply_text}))
				tile.current_health -= f32(e.damage_low * multiply)
			}

			if tile.current_health <= 0 {
				append(&ctx.gs.last_actions, strings.concatenate({tile.name, " is dead"}))
				ctx.gs.current_target = nil
			}
		}
		else { //TALK
			get_player().in_discussion = true
			tile.in_discussion = true
			ctx.gs.current_target = tile
			clear(&ctx.gs.dialog_text)
			append(&ctx.gs.dialog_text, "What do you want ?")
			append(&ctx.gs.dialog_text, "")
			append(&ctx.gs.dialog_text, "Press E to close")
		}
	}
	else if cell.kind == .work_selection {
		clear(&ctx.gs.quest_available)
		append(&ctx.gs.quest_available, ctx.gs.all_quests[0])
		ctx.gs.selecting_quest = true
		append(&ctx.gs.last_actions, strings.concatenate({"Inspected : ", cell.name}))
		get_player().in_discussion = true
	}
	else {
		append(&ctx.gs.last_actions, strings.concatenate({"Inspected : ", cell.name}))
	}
}

check_cell :: proc(index: int) -> ^Entity {
	if ctx.gs.all_cells_entity[index] != nil && 
		ctx.gs.all_cells_entity[index].can_be_interact_with == true {
			return ctx.gs.all_cells_entity[index]
	}
	return nil
}

setup_thing1 :: proc(using e: ^Entity) {
	kind = .thing1
}

setup_ai :: proc(using e: ^Entity) {
	e.kind = .ai

	e.name = "Davis Moore"
	e.sprite = .player_tile;
	e.can_be_interact_with = true
	e.enemy = false
	e.max_health = 30
	e.current_health = e.max_health

	e.last_movement = Input_Action.left

	e.update_proc = proc(e: ^Entity) {
		pos := mouse_pos_in_current_space()
		if pos.x > e.pos.x - 8 && pos.x < e.pos.x + 8 && pos.y > e.pos.y && pos.y < e.pos.y + 16 {
			ctx.gs.force_hint_text = e.name
			if input.key_pressed(.LEFT_MOUSE) {
				DEBUG_ENTITY = e
			}
		}

		if e.in_discussion {
			return
		}

		if e.move_to_path {
			if e.can_move == false {
				e.time_to_move -= ctx.delta_t
				if e.time_to_move <= 0 {
					e.time_to_move = 0
					e.can_move = true	
				}
			}
			else {
				e.parent_entity.can_be_interact_with = false
				e.parent_entity.child_entity =  nil
				
				e.x = e.path[e.path_index].x
				e.y = e.path[e.path_index].y
				e.pos.x = f32(e.x) * 16
				e.pos.y = starting_y + f32(e.y) * 16
				e.path_index += 1
				if e.path_index >= len(e.path) {
					//e.move_to_path = false
					e.path_index = 0
					e.path = move_to(e, ctx.gs.all_interest_points[rand.int31_max(i32(len(ctx.gs.all_interest_points)))])
				}
				e.parent_entity = ctx.gs.all_cells_entity[int(e.y) * TILE_WIDTH + int(e.x)]
				e.parent_entity.can_be_interact_with = true
				e.parent_entity.child_entity = e
				e.time_to_move = 0.5
				e.can_move = false
			}
			return
		}
	}

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_wall :: proc(using e: ^Entity) {
	e.kind = .wall

	e.name = "wall"
	e.sprite = .wall;

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_dot :: proc(using e: ^Entity) {
	e.kind = .dot

	e.name = "dot"
	e.sprite = .dot;

	e.update_proc = proc(e: ^Entity) {
		pos := mouse_pos_in_current_space()
		if pos.x > e.pos.x - 8 && pos.x < e.pos.x + 8 && pos.y > e.pos.y && pos.y < e.pos.y + 16 {
			if input.key_pressed(.RIGHT_MOUSE) && DEBUG_ENTITY != nil {
				DEBUG_ENTITY.path = move_to(DEBUG_ENTITY, e)
				DEBUG_ENTITY.move_to_path = true
				DEBUG_ENTITY.path_index = 0
			}
		}
	}

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_door :: proc(using e: ^Entity) {
	e.kind = .door

	e.name = "door"
	e.sprite = .door;
	e.can_be_interact_with = true
	random := rand.int31_max(4)
	e.door_level = bald_user.Door_Level(random)

	e.update_proc = proc(e: ^Entity) {
		if ctx.gs.time_hour >= 20 && e.door_state == bald_user.Door_State.Open && !e.unlocked{
			e.door_state = bald_user.Door_State.Locked
			e.sprite = .door_closed
			ctx.gs.all_cells[int(e.y) * TILE_WIDTH + int(e.x)] = true
		}
		pos := mouse_pos_in_current_space()
		if pos.x > e.pos.x - 8 && pos.x < e.pos.x + 8 && pos.y > e.pos.y && pos.y < e.pos.y + 16 {
			if e.building_index != 0 {
				buf: [4]byte
				result := strconv.itoa(buf[:], int(e.building_index))
				str := string(result)
				ctx.gs.force_hint_text = strings.concatenate({"Building ", str})
			}
			if input.key_pressed(.RIGHT_MOUSE) && DEBUG_ENTITY != nil {
				DEBUG_ENTITY.path = move_to(DEBUG_ENTITY, e)
				DEBUG_ENTITY.move_to_path = true
				DEBUG_ENTITY.path_index = 0
			}
		}
	}

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_stairs_up :: proc(using e: ^Entity) {
	e.kind = .stairs_up

	e.name = "stairs_up"
	e.sprite = .stairs_up
	e.special_tile = true
	e.on_trigger_tile = true

	append(&ctx.gs.all_interest_points, e)

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_restaurant :: proc(using e: ^Entity) {
	e.kind = .restaurant

	e.name = "restaurant"
	e.sprite = .restaurant;
	append(&ctx.gs.all_interest_points, e)

	e.update_proc = proc(e: ^Entity) {
		pos := mouse_pos_in_current_space()
		if pos.x > e.pos.x - 8 && pos.x < e.pos.x + 8 && pos.y > e.pos.y && pos.y < e.pos.y + 16 {
			ctx.gs.force_hint_text = e.name
		}
	}

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_police :: proc(using e: ^Entity) {
	e.kind = .police

	e.name = "police"
	e.sprite = .police;
	append(&ctx.gs.all_interest_points, e)

	e.update_proc = proc(e: ^Entity) {
		pos := mouse_pos_in_current_space()
		if pos.x > e.pos.x - 8 && pos.x < e.pos.x + 8 && pos.y > e.pos.y && pos.y < e.pos.y + 16 {
			ctx.gs.force_hint_text = e.name
		}
	}

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_work_selection :: proc(using e: ^Entity) {
	e.kind = .work_selection

	e.name = "work selection"
	e.sprite = .work_selection;
	e.can_be_interact_with = true
	append(&ctx.gs.all_interest_points, e)

	e.update_proc = proc(e: ^Entity) {
		pos := mouse_pos_in_current_space()
		if pos.x > e.pos.x - 8 && pos.x < e.pos.x + 8 && pos.y > e.pos.y && pos.y < e.pos.y + 16 {
			ctx.gs.force_hint_text = e.name
		}
	}

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

//
// items

setup_lockpick :: proc(using e: ^Entity) {
	e.kind = .lockpick

	e.name = "lockpick"
	e.max_health = 100
	e.current_health = e.max_health
}

setup_baton :: proc(using e: ^Entity) {
	e.kind = .baton

	e.name = "baton"
	e.value_min = 1
	e.value_max = 3
}

//
// animation

entity_set_animation :: proc(e: ^Entity, sprite: Sprite_Name, frame_duration: f32, looping:=true) {
	if e.sprite != sprite {
		e.sprite = sprite
		e.loop = looping
		e.frame_duration = frame_duration
		e.anim_index = 0
		e.next_frame_end_time = 0
	}
}

update_entity_animation :: proc(e: ^Entity) {
	if e.frame_duration == 0 do return

	frame_count := get_frame_count(e.sprite)

	is_playing := true
	if !e.loop {
		is_playing = e.anim_index + 1 <= frame_count
	}

	if is_playing {
	
		if e.next_frame_end_time == 0 {
			e.next_frame_end_time = now() + f64(e.frame_duration)
		}
	
		if end_time_up(e.next_frame_end_time) {
			e.anim_index += 1
			e.next_frame_end_time = 0
			//e.did_frame_advance = true
			if e.anim_index >= frame_count {

				if e.loop {
					e.anim_index = 0
				}

			}
		}
	}
}

// TIME

move_time :: proc() {
	ctx.gs.time_minute += 3
	if ctx.gs.time_minute >= 60 {
		ctx.gs.time_minute -= 60
		ctx.gs.time_hour += 1
		if ctx.gs.time_hour > 23 {
			ctx.gs.time_hour = 0
			ctx.gs.day += 1
		}
	}
}

// COMMAND

analyse_command :: proc(command: string) {
	ss := strings.split(command, " ")
	if ss[0] == "god" {
		get_player().intelligence = 100
		get_player().vitality = 100
		get_player().chance = 100
		get_player().lockpick = 100
		get_player().hack = 100
		get_player().endurance = 100
		get_player().power = 100
		get_player().charisma = 100
		get_player().max_health = 9999
		get_player().current_health = get_player().max_health
	}
	else if ss[0] == "set" {
		if ss[1] == "pos" && len (ss) < 6 {
			if ss[4] == "0" { // PLAYER
				x, ok := strconv.parse_int(ss[2])
				y, ok2 := strconv.parse_int(ss[3])

				ctx.gs.player_cell_x = x
				ctx.gs.player_cell_y = y
				ctx.gs.player_cell = ctx.gs.player_cell_y * TILE_WIDTH + ctx.gs.player_cell_x

				get_player().pos = Vec2({f32(x) * 16, starting_y + f32(y) * 16})
			}
			log.info("unknonw command :", command)
		}
		else {
			if len (ss) < 3 {
				log.info("unknonw command :", command)
				return
			}
			if ss[3] == "0" { // PLAYER
				if ss[1] == "int" {
					n, ok := strconv.parse_int(ss[2])
					get_player().intelligence = n
				}
				else if ss[1] == "vit" {
					n, ok := strconv.parse_int(ss[2])
					get_player().vitality = n
				}
				else if ss[1] == "chan" {
					n, ok := strconv.parse_int(ss[2])
					get_player().chance = n
				}
				else if ss[1] == "lock" {
					n, ok := strconv.parse_int(ss[2])
					get_player().lockpick = n
				}
				else if ss[1] == "hack" {
					n, ok := strconv.parse_int(ss[2])
					get_player().hack = n
				}
				else if ss[1] == "end" {
					n, ok := strconv.parse_int(ss[2])
					get_player().endurance = n
				}
				else if ss[1] == "pow" {
					n, ok := strconv.parse_int(ss[2])
					get_player().power = n
				}
				else if ss[1] == "char" {
					n, ok := strconv.parse_int(ss[2])
					get_player().charisma = n
				}
				else {
					log.info("unknonw command :", command)
				}
			}
		}
	}
}

move_to :: proc(ai: ^Entity, target: ^Entity) -> [dynamic]^Entity{
	to_return: [dynamic]^Entity

	to_explore: [dynamic]^path_find_cell
	explored: [dynamic]^Entity
	
	final: [dynamic]^path_find_cell

	starting_cell := ai.parent_entity
	previous_cell := starting_cell
	last_path_find_cell := new(path_find_cell)
	last_path_find_cell.comes_from = nil
	last_path_find_cell.linked_entity = starting_cell
	last_path_find_cell.weight = 1
	current_cell: ^path_find_cell = last_path_find_cell

	new_path_find_cell := new(path_find_cell)
	new_path_find_cell.comes_from = last_path_find_cell
	new_path_find_cell.linked_entity = ctx.gs.all_cells_entity[int(starting_cell.y) * TILE_WIDTH + int(starting_cell.x + 1)]
	append(&to_explore, new_path_find_cell)

	new_path_find_cell = new(path_find_cell)
	new_path_find_cell.comes_from = last_path_find_cell
	new_path_find_cell.linked_entity = ctx.gs.all_cells_entity[int(starting_cell.y) * TILE_WIDTH + int(starting_cell.x - 1)]
	append(&to_explore, new_path_find_cell)

	new_path_find_cell = new(path_find_cell)
	new_path_find_cell.comes_from = last_path_find_cell
	new_path_find_cell.linked_entity = ctx.gs.all_cells_entity[int(starting_cell.y - 1) * TILE_WIDTH + int(starting_cell.x)]
	append(&to_explore, new_path_find_cell)

	new_path_find_cell = new(path_find_cell)
	new_path_find_cell.comes_from = last_path_find_cell
	new_path_find_cell.linked_entity = ctx.gs.all_cells_entity[int(starting_cell.y + 1) * TILE_WIDTH + int(starting_cell.x)]
	append(&to_explore, new_path_find_cell)

	for {
		if current_cell.linked_entity == target || len(to_explore) <= 0 
		{
			break
		}

		current_cell = to_explore[0]

		if current_cell.linked_entity == target
		{
			new_path: ^path_find_cell = new(path_find_cell)
			new_path.comes_from = current_cell
			new_path.linked_entity = target
			new_path.weight = current_cell.weight
			append(&final, new_path)
			break
		}

		distance := bald_user.dist(target.pos, current_cell.linked_entity.pos)
		index_to_remove := 0
		i := 0
		for single_cell in to_explore {
			distance_bis := bald_user.dist(target.pos, single_cell.linked_entity.pos)
			if distance_bis < distance {
				current_cell = single_cell
				distance = distance_bis
				index_to_remove = i
			}
			i += 1
		}

		append(&explored, current_cell.linked_entity)
		ordered_remove(&to_explore, index_to_remove)

		append(&final, current_cell)

		to_check: ^Entity = nil
		if int(current_cell.linked_entity.y) * TILE_WIDTH + int(current_cell.linked_entity.x + 1) > 0 {
			to_check = ctx.gs.all_cells_entity[int(current_cell.linked_entity.y) * TILE_WIDTH + int(current_cell.linked_entity.x + 1)]
			if !contains_entity_from_path_find_cell(to_explore, to_check) && !contains_entity(explored, to_check) {
				if to_check.kind != .wall {
					new_path_find_cell = new(path_find_cell)
					new_path_find_cell.comes_from = current_cell
					new_path_find_cell.linked_entity = to_check
					append(&to_explore, new_path_find_cell)
				}
			}
		}

		if int(current_cell.linked_entity.y) * TILE_WIDTH + int(current_cell.linked_entity.x - 1) > 0 {
			to_check = ctx.gs.all_cells_entity[int(current_cell.linked_entity.y) * TILE_WIDTH + int(current_cell.linked_entity.x - 1)]
			if !contains_entity_from_path_find_cell(to_explore, to_check) && !contains_entity(explored, to_check) {
				if to_check.kind != .wall {
					new_path_find_cell = new(path_find_cell)
					new_path_find_cell.comes_from = current_cell
					new_path_find_cell.linked_entity = to_check
					append(&to_explore, new_path_find_cell)
				}
			}
		}

		if int(current_cell.linked_entity.y - 1) * TILE_WIDTH + int(current_cell.linked_entity.x) > 0 {
			to_check = ctx.gs.all_cells_entity[int(current_cell.linked_entity.y - 1) * TILE_WIDTH + int(current_cell.linked_entity.x)]
			if !contains_entity_from_path_find_cell(to_explore, to_check) && !contains_entity(explored, to_check) {
				if to_check.kind != .wall {
					new_path_find_cell = new(path_find_cell)
					new_path_find_cell.comes_from = current_cell
					new_path_find_cell.linked_entity = to_check
					append(&to_explore, new_path_find_cell)
				}
			}
		}
		
		if int(current_cell.linked_entity.y + 1) * TILE_WIDTH + int(current_cell.linked_entity.x) > 0 {
			to_check = ctx.gs.all_cells_entity[int(current_cell.linked_entity.y + 1) * TILE_WIDTH + int(current_cell.linked_entity.x)]
			if !contains_entity_from_path_find_cell(to_explore, to_check) && !contains_entity(explored, to_check) {
				if to_check.kind != .wall {
					new_path_find_cell = new(path_find_cell)
					new_path_find_cell.comes_from = current_cell
					new_path_find_cell.linked_entity = to_check
					append(&to_explore, new_path_find_cell)
				}
			}
		}
	}

	inverted: [dynamic]^path_find_cell
	if current_cell.linked_entity == target {
		examined_cell := final[len(final) - 1]
		append(&inverted, examined_cell)
		for {
			if examined_cell.linked_entity == starting_cell {
				break
			}
			append(&inverted, examined_cell.comes_from)
			examined_cell = examined_cell.comes_from
			
		}
	}
	else {
		log.debug("cannot reach the path")
	}

	for i := len(inverted) -1 ; i >= 0; i -= 1 {
		append(&to_return, inverted[i].linked_entity)
	}

	return to_return
}

//
// Pathfind
path_find_cell :: struct {
	comes_from: ^path_find_cell,
	linked_entity: ^Entity,
	weight: int,
}

contains_entity :: proc(array: [dynamic]^Entity, e: ^Entity) -> bool{
	for entity in array {
		if entity  == e {
			return true
		}
	}

	return false
}

contains_entity_from_path_find_cell :: proc(array: [dynamic]^path_find_cell, e: ^Entity) -> bool{
	for entity in array {
		if entity.linked_entity  == e {
			return true
		}
	}

	return false
}

// 
// Quest

start_quest :: proc() {

}