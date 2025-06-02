/*

This is a helper to save and load data during game

*/

package utils

import "core:encoding/json"
import "core:log"
import "core:os"

Save_Bool :: struct {
	id: string,
    value: bool,
}

Save_Int :: struct {
	id: string,
    value: int,
}

Save_Float :: struct {
	id: string,
    value: f64,
}

Save_String :: struct {
	id: string,
    value: string,
}

All_Save :: struct {
	saved_bools : [dynamic]Save_Bool,
	saved_ints : [dynamic]Save_Int,
	saved_floats : [dynamic]Save_Float,
	saved_strings : [dynamic]Save_String,
}

all_saves : All_Save

save_name :: "./PlayerPref.json"

save_player_prefs :: proc() {
    if json_data, err := json.marshal(all_saves, allocator = context.temp_allocator); err == nil {
        if !os.write_entire_file(save_name, json_data) {
            log.debug("Couldn't write file!")
        }
    } else {
        log.debug("Couldn't marshal struct!")
    }
}

load_player_prefs :: proc() {
    if json_data, ok := os.read_entire_file(save_name, context.temp_allocator); ok {
        if json.unmarshal(json_data, &all_saves) != nil {
            log.debug("Failed to unmarshal JSON")
        }
    } else {
        log.debug("Failed to read my_struct_file")
        save_player_prefs()
    }
}

set_bool :: proc(input_id: string, input_value: bool)
{
    for &saved in all_saves.saved_bools {
        if saved.id == input_id {
            saved.value = input_value
            return
        }
    }

    append(&all_saves.saved_bools, Save_Bool({input_id, input_value}))
}

get_bool :: proc(input_id: string) -> bool
{
    for saved in all_saves.saved_bools {
        if saved.id == input_id {
            return saved.value
        }
    }

    log.error("Cannot find any saved bool for ", input_id)
    return false
}

set_int :: proc(input_id: string, input_value: int)
{
    for &saved in all_saves.saved_ints {
        if saved.id == input_id {
            saved.value = input_value
            return
        }
    }

    append(&all_saves.saved_ints, Save_Int({input_id, input_value}))
}

get_int :: proc(input_id: string) -> int
{
    for saved in all_saves.saved_ints {
        if saved.id == input_id {
            return saved.value
        }
    }

    log.error("Cannot find any saved int for ", input_id)
    return -1
}

set_float :: proc(input_id: string, input_value: f64)
{
    for &saved in all_saves.saved_floats {
        if saved.id == input_id {
            saved.value = input_value
            return
        }
    }

    append(&all_saves.saved_floats, Save_Float({input_id, input_value}))
}

get_float :: proc(input_id: string) -> f64
{
    for saved in all_saves.saved_floats {
        if saved.id == input_id {
            return saved.value
        }
    }

    log.error("Cannot find any saved float for ", input_id)
    return -1
}

set_string :: proc(input_id: string, input_value: string)
{
    for &saved in all_saves.saved_strings {
        if saved.id == input_id {
            saved.value = input_value
            return
        }
    }

    append(&all_saves.saved_strings, Save_String({input_id, input_value}))
}

get_string :: proc(input_id: string) -> string
{
    for saved in all_saves.saved_strings {
        if saved.id == input_id {
            return saved.value
        }
    }

    log.error("Cannot find any saved string for ", input_id)
    return ""
}