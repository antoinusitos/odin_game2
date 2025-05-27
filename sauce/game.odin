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
TILE_WIDTH :: 80
TILE_HEIGHT :: 35
window_w := 1280
window_h := 720
map_path := "./tiled/sans titre.tmj"
starting_y : f32 = 16 * 5

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

	// sloppy state dump
	player_handle: Entity_Handle,
	player_cell: int,
	player_cell_x: int,
	player_cell_y: int,

	all_cells: [TILE_WIDTH * TILE_HEIGHT]bool,
	all_cells_entity: [TILE_WIDTH * TILE_HEIGHT]^Entity,

	time_hour: int,
	time_minute: int,
	tick_to_minute: f64,
	day: int,
	month: bald_user.Month,
	year: int,

	last_actions: [dynamic]string,

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

	max_health: f32,
	current_health: f32,

	//stats
	vitality: int,
	chance: int,
	lockpick: int,
	hack: int,
	endurance: int,
	mana: int,
	
	// this gets zeroed every frame. Useful for passing data to other systems.
	scratch: struct {
		col_override: Vec4,
	}
}

Entity_Kind :: enum {
	nil,
	player,
	thing1,
	tile,
	tile2,
	tile3,
	tile4,
	tile5,
	tile6,
	tile7,
	tile8,
	tile9,
	wall,
	dot,
	door,
}

entity_setup :: proc(e: ^Entity, kind: Entity_Kind) {
	// entity defaults
	e.draw_proc = draw_entity_default
	e.draw_pivot = .bottom_center

	switch kind {
		case .nil:
		case .player: setup_player(e)
		case .thing1: setup_thing1(e)
		case .tile: setup_tile(e)
		case .tile2: setup_tile2(e)
		case .tile3: setup_tile3(e)
		case .tile4: setup_tile4(e)
		case .tile5: setup_tile5(e)
		case .tile6: setup_tile6(e)
		case .tile7: setup_tile7(e)
		case .tile8: setup_tile8(e)
		case .tile9: setup_tile9(e)
		case .wall: setup_wall(e)
		case .dot: setup_dot(e)
		case .door: setup_door(e)
	}
}

//
// main game procs

app_init :: proc() {
}

app_frame :: proc() {

	// right now we are just calling the game update, but in future this is where you'd do a big
	// "UX" switch for startup splash, main menu, settings, in-game, etc

	{
		game_ui()
	}

	sound.play_continuously("event:/ambiance", "")

	game_update()
	game_draw()

	volume :f32= 0.75
	sound.update(get_player().pos, volume)
}

app_shutdown :: proc() {
	// called on exit

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

	// STATS
	result = strconv.itoa(buf[:], int(player.vitality))
	str = string(result)
	vitality_string : string = strings.concatenate({"Vitality : ", str})
	draw.draw_text({screen_x + 150, screen_y - 2}, vitality_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.chance))
	str = string(result)
	chance_string : string =  strings.concatenate({"Chance : ", str})
	draw.draw_text({screen_x + 300, screen_y - 2}, chance_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.endurance))
	str = string(result)
	endurance_string : string =  strings.concatenate({"Endurance : ", str})
	draw.draw_text({screen_x + 450, screen_y - 2}, endurance_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.lockpick))
	str = string(result)
	lockpick_string : string =  strings.concatenate({"Lockpick : ", str})
	draw.draw_text({screen_x + 2, screen_y - 2}, lockpick_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.hack))
	str = string(result)
	hack_string : string =  strings.concatenate({"Hack : ", str})
	draw.draw_text({screen_x + 600, screen_y - 2}, hack_string, z_layer=.ui, pivot=Pivot.top_left)

	result = strconv.itoa(buf[:], int(player.mana))
	str = string(result)
	mana_string : string =  strings.concatenate({"Mana : ", str})
	draw.draw_text({screen_x + 750, screen_y - 2}, mana_string, z_layer=.ui, pivot=Pivot.top_left)

	// ACTIONS
	screen_x, screen_y = screen_pivot(.bottom_left)
	action_index := 0
	for action_it_index := len(ctx.gs.last_actions) - 1; action_it_index >= 0; action_it_index -= 1 {
		if len(ctx.gs.last_actions) > action_it_index {
			draw.draw_text({screen_x + 2, screen_y + 15 + f32(action_index * 15)}, ctx.gs.last_actions[action_it_index], z_layer=.ui, pivot=Pivot.top_left)
			action_index += 1
			if action_index >= 5 {
				break
			}
		}
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
}

game_init :: proc() {
	ctx.gs.time_hour = 9
	ctx.gs.time_minute = 0

	ctx.gs.day = 14
	ctx.gs.month = bald_user.Month.April
	ctx.gs.year = 2067

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
		if id == 27 {
			p = entity_create(.tile)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
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
			p = entity_create(.tile2)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 450 {
			p = entity_create(.door)
			ctx.gs.all_cells[i] = false
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 448 {
			p = entity_create(.door)
			ctx.gs.all_cells[i] = false
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 320 {
			p = entity_create(.tile3)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 224 {
			p = entity_create(.tile4)
			ctx.gs.all_cells[i] = true
			ctx.gs.all_cells_entity[i] = p
		}
		else if id == 173 {
			p = entity_create(.tile5)
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
		}

		i += 1
	}

	player := entity_create(.player)
	ctx.gs.player_handle = player.handle
	player.pos = Vec2{0, starting_y}
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
	}

	utils.animate_to_target_v2(&ctx.gs.cam_pos, get_player().pos, ctx.delta_t, rate=10)

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
	e.mana = 5

	e.update_proc = proc(e: ^Entity) {

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
				cell := check_cell(ctx.gs.player_cell_y * TILE_WIDTH + ctx.gs.player_cell_x - 1)
				if cell != nil{
					append(&ctx.gs.last_actions, strings.concatenate({"Inspected : ", cell.name}))
				}
			}
			if ctx.gs.player_cell_x < TILE_WIDTH - 1 {
				//right
				cell := check_cell(ctx.gs.player_cell_y * TILE_WIDTH + ctx.gs.player_cell_x + 1)
				if cell != nil{
					append(&ctx.gs.last_actions, strings.concatenate({"Inspected : ", cell.name}))
				}
			}
			if ctx.gs.player_cell_y > 0 {
				//bottom
				cell := check_cell((ctx.gs.player_cell_y - 1) * TILE_WIDTH + ctx.gs.player_cell_x)
				if cell != nil{
					append(&ctx.gs.last_actions, strings.concatenate({"Inspected : ", cell.name}))
				}
			}
			if ctx.gs.player_cell_y < TILE_HEIGHT - 1 {
				//top
				cell := check_cell((ctx.gs.player_cell_y + 1) * TILE_WIDTH + ctx.gs.player_cell_x)
				if cell != nil{
					if cell.kind == .door {
						chance : f32 = f32(e.chance) / 100
						success :i32 = 50 + i32(chance) * 100
						random := rand.int31_max(101)
						log.debug(success)
						log.debug(random)
						if success >= random {
							append(&ctx.gs.last_actions, strings.concatenate({"lockpicked : ", cell.name}))
							e.lockpick += 1
						}
						else {
							append(&ctx.gs.last_actions, strings.concatenate({"fail to lockpick : ", cell.name}))
						}
					}
					else {
						append(&ctx.gs.last_actions, strings.concatenate({"Inspected : ", cell.name}))
					}
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

check_cell :: proc(index: int) -> ^Entity {
	if ctx.gs.all_cells_entity[index] != nil && 
		ctx.gs.all_cells_entity[index].kind != .dot {
			return ctx.gs.all_cells_entity[index]
	}
	return nil
}

setup_thing1 :: proc(using e: ^Entity) {
	kind = .thing1
}

setup_tile :: proc(using e: ^Entity) {
	e.kind = .tile

	e.name = "tile"
	e.sprite = .playertile;

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_tile2 :: proc(using e: ^Entity) {
	e.kind = .tile2

	e.name = "tile2"
	e.sprite = .playertile2;

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_tile3 :: proc(using e: ^Entity) {
	e.kind = .tile3

	e.name = "tile3"
	e.sprite = .playertile3;

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_tile4 :: proc(using e: ^Entity) {
	e.kind = .tile4

	e.name = "tile4"
	e.sprite = .playertile4;

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_tile5 :: proc(using e: ^Entity) {
	e.kind = .tile5

	e.name = "tile5"
	e.sprite = .playertile5;

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_tile6 :: proc(using e: ^Entity) {
	e.kind = .tile6

	e.name = "tile6"
	e.sprite = .playertile6;

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_tile7 :: proc(using e: ^Entity) {
	e.kind = .tile7

	e.name = "tile7"
	e.sprite = .playertile7;

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_tile8 :: proc(using e: ^Entity) {
	e.kind = .tile8

	e.name = "tile8"
	e.sprite = .playertile8;

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_tile9 :: proc(using e: ^Entity) {
	e.kind = .tile9

	e.name = "tile9"
	e.sprite = .playertile9;

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

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

setup_door :: proc(using e: ^Entity) {
	e.kind = .door

	e.name = "door"
	e.sprite = .door;

	e.draw_proc = proc(e: Entity) {
		draw_entity_default(e)
	}
}

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