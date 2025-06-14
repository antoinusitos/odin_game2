// Copyright (c) Epic Games Tools
// Licensed under the MIT license (https://opensource.org/license/mit/)

#undef LAYER_COLOR
#define LAYER_COLOR 0xfffa00ff

////////////////////////////////
//~ rjf: Basic Helpers

internal U64
fs_little_hash_from_string(String8 string)
{
  U64 result = 5381;
  for(U64 i = 0; i < string.size; i += 1)
  {
    result = ((result << 5) + result) + string.str[i];
  }
  return result;
}

internal U128
fs_big_hash_from_string_range(String8 string, Rng1U64 range)
{
  Temp scratch = scratch_begin(0, 0);
  U64 buffer_size = string.size + sizeof(U64)*2;
  U8 *buffer = push_array_no_zero(scratch.arena, U8, buffer_size);
  MemoryCopy(buffer, string.str, string.size);
  MemoryCopy(buffer + string.size, &range.min, sizeof(range.min));
  MemoryCopy(buffer + string.size + sizeof(range.min), &range.max, sizeof(range.max));
  U128 hash = hs_hash_from_data(str8(buffer, buffer_size));
  scratch_end(scratch);
  return hash;
}

////////////////////////////////
//~ rjf: Top-Level API

internal void
fs_init(void)
{
  Arena *arena = arena_alloc();
  fs_shared = push_array(arena, FS_Shared, 1);
  fs_shared->arena = arena;
  fs_shared->change_gen = 1;
  fs_shared->slots_count = 1024;
  fs_shared->stripes_count = os_get_system_info()->logical_processor_count;
  fs_shared->slots = push_array(arena, FS_Slot, fs_shared->slots_count);
  fs_shared->stripes = push_array(arena, FS_Stripe, fs_shared->stripes_count);
  for(U64 idx = 0; idx < fs_shared->stripes_count; idx += 1)
  {
    fs_shared->stripes[idx].arena = arena_alloc();
    fs_shared->stripes[idx].cv = os_condition_variable_alloc();
    fs_shared->stripes[idx].rw_mutex = os_rw_mutex_alloc();
  }
  fs_shared->u2s_ring_size = KB(64);
  fs_shared->u2s_ring_base = push_array_no_zero(arena, U8, fs_shared->u2s_ring_size);
  fs_shared->u2s_ring_cv = os_condition_variable_alloc();
  fs_shared->u2s_ring_mutex = os_mutex_alloc();
  fs_shared->detector_thread = os_thread_launch(fs_detector_thread__entry_point, 0, 0);
}

////////////////////////////////
//~ rjf: Change Generation

internal U64
fs_change_gen(void)
{
  return ins_atomic_u64_eval(&fs_shared->change_gen);
}

////////////////////////////////
//~ rjf: Cache Interaction

internal HS_Key
fs_key_from_path_range(String8 path, Rng1U64 range, U64 endt_us)
{
  Temp scratch = scratch_begin(0, 0);
  
  //- rjf: unpack args
  path = path_normalized_from_string(scratch.arena, path);
  U64 path_little_hash = fs_little_hash_from_string(path);
  U64 path_slot_idx = path_little_hash%fs_shared->slots_count;
  U64 path_stripe_idx = path_slot_idx%fs_shared->stripes_count;
  FS_Slot *path_slot = &fs_shared->slots[path_slot_idx];
  FS_Stripe *path_stripe = &fs_shared->stripes[path_stripe_idx];
  
  //- rjf: get root for this path
  HS_Root root = {0};
  OS_MutexScopeR(path_stripe->rw_mutex)
  {
    B32 node_found = 0;
    for(FS_Node *n = path_slot->first; n != 0; n = n->next)
    {
      if(str8_match(n->path, path, 0))
      {
        node_found = 1;
        root = n->root;
        break;
      }
    }
    if(!node_found) OS_MutexScopeRWPromote(path_stripe->rw_mutex)
    {
      B32 node_found = 0;
      for(FS_Node *n = path_slot->first; n != 0; n = n->next)
      {
        if(str8_match(n->path, path, 0))
        {
          node_found = 1;
          root = n->root;
          break;
        }
      }
      if(!node_found)
      {
        FS_Node *node = push_array(path_stripe->arena, FS_Node, 1);
        SLLQueuePush(path_slot->first, path_slot->last, node);
        node->path = push_str8_copy(path_stripe->arena, path);
        node->root = hs_root_alloc();
        node->slots_count = 64;
        node->slots = push_array(path_stripe->arena, FS_RangeSlot, node->slots_count);
        root = node->root;
      }
    }
  }
  
  //- rjf: build a key for this path/range combo
  HS_Key key = hs_key_make(root, hs_id_make(range.min, range.max));
  
  //- rjf: if the most recent hash for this key is zero, then try to submit a new
  // request to pull it in.
  if(u128_match(hs_hash_from_key(key, 0), u128_zero()))
  {
    // rjf: loop: request, check for results, return until we can't
    OS_MutexScopeW(path_stripe->rw_mutex) for(;;)
    {
      // rjf: path -> node
      FS_Node *node = 0;
      for(FS_Node *n = path_slot->first; n != 0; n = n->next)
      {
        if(str8_match(path, n->path, 0))
        {
          node = n;
          break;
        }
      }
      
      // rjf: no node? -> weird case, node should've been made at this point.
      if(node == 0)
      {
        break;
      }
      
      // rjf: range -> node
      U64 range_hash = fs_little_hash_from_string(str8_struct(&key.id));
      U64 range_slot_idx = range_hash%node->slots_count;
      FS_RangeSlot *range_slot = &node->slots[range_slot_idx];
      FS_RangeNode *range_node = 0;
      for(FS_RangeNode *n = range_slot->first; n != 0; n = n->next)
      {
        if(hs_id_match(n->id, key.id))
        {
          range_node = n;
          break;
        }
      }
      
      // rjf: range node does not exist? create & store
      if(range_node == 0)
      {
        range_node = push_array(path_stripe->arena, FS_RangeNode, 1);
        SLLQueuePush(range_slot->first, range_slot->last, range_node);
        range_node->id = key.id;
      }
      
      // rjf: try to send stream request
      if(ins_atomic_u64_eval(&range_node->working_count) == 0 &&
         fs_u2s_enqueue_req(key, range, path, endt_us))
      {
        ins_atomic_u64_inc_eval(&range_node->working_count);
        DeferLoop(os_rw_mutex_drop_w(path_stripe->rw_mutex), os_rw_mutex_take_w(path_stripe->rw_mutex))
        {
          async_push_work(fs_stream_work, .working_counter = &range_node->working_count);
        }
      }
      
      // rjf: have time to wait? -> wait on this stripe; otherwise exit
      B32 have_results = !u128_match(hs_hash_from_key(key, 0), u128_zero());
      if(!have_results && os_now_microseconds() < endt_us)
      {
        os_condition_variable_wait_rw_w(path_stripe->cv, path_stripe->rw_mutex, endt_us);
      }
      else
      {
        break;
      }
    }
  }
  
  scratch_end(scratch);
  return key;
}

internal U128
fs_hash_from_path_range(String8 path, Rng1U64 range, U64 endt_us)
{
  U128 hash = {0};
  {
    HS_Key key = fs_key_from_path_range(path, range, endt_us);
    for EachIndex(rewind_idx, HS_KEY_HASH_HISTORY_COUNT)
    {
      hash = hs_hash_from_key(key, rewind_idx);
      if(!u128_match(hash, u128_zero()))
      {
        break;
      }
    }
  }
  return hash;
}

internal FileProperties
fs_properties_from_path(String8 path)
{
  Temp scratch = scratch_begin(0, 0);
  FileProperties result = {0};
  path = path_normalized_from_string(scratch.arena, path);
  U64 path_hash = fs_little_hash_from_string(path);
  U64 slot_idx = path_hash%fs_shared->slots_count;
  U64 stripe_idx = slot_idx%fs_shared->stripes_count;
  FS_Slot *slot = &fs_shared->slots[slot_idx];
  FS_Stripe *stripe = &fs_shared->stripes[stripe_idx];
  OS_MutexScopeR(stripe->rw_mutex)
  {
    for(FS_Node *n = slot->first; n != 0; n = n->next)
    {
      if(str8_match(path, n->path, 0))
      {
        result = n->props;
        break;
      }
    }
  }
  scratch_end(scratch);
  return result;
}

////////////////////////////////
//~ rjf: Streamer Threads

internal B32
fs_u2s_enqueue_req(HS_Key key, Rng1U64 range, String8 path, U64 endt_us)
{
  B32 result = 0;
  path.size = Min(path.size, fs_shared->u2s_ring_size);
  OS_MutexScope(fs_shared->u2s_ring_mutex) for(;;)
  {
    U64 unconsumed_size = fs_shared->u2s_ring_write_pos - fs_shared->u2s_ring_read_pos;
    U64 available_size = fs_shared->u2s_ring_size - unconsumed_size;
    U64 needed_size = sizeof(key) + sizeof(range.min) + sizeof(range.max) + sizeof(path.size) + path.size;
    if(available_size >= needed_size)
    {
      result = 1;
      fs_shared->u2s_ring_write_pos += ring_write_struct(fs_shared->u2s_ring_base, fs_shared->u2s_ring_size, fs_shared->u2s_ring_write_pos, &key);
      fs_shared->u2s_ring_write_pos += ring_write_struct(fs_shared->u2s_ring_base, fs_shared->u2s_ring_size, fs_shared->u2s_ring_write_pos, &range.min);
      fs_shared->u2s_ring_write_pos += ring_write_struct(fs_shared->u2s_ring_base, fs_shared->u2s_ring_size, fs_shared->u2s_ring_write_pos, &range.max);
      fs_shared->u2s_ring_write_pos += ring_write_struct(fs_shared->u2s_ring_base, fs_shared->u2s_ring_size, fs_shared->u2s_ring_write_pos, &path.size);
      fs_shared->u2s_ring_write_pos += ring_write(fs_shared->u2s_ring_base, fs_shared->u2s_ring_size, fs_shared->u2s_ring_write_pos, path.str, path.size);
      break;
    }
    os_condition_variable_wait(fs_shared->u2s_ring_cv, fs_shared->u2s_ring_mutex, endt_us);
  }
  if(result)
  {
    os_condition_variable_broadcast(fs_shared->u2s_ring_cv);
  }
  return result;
}

internal void
fs_u2s_dequeue_req(Arena *arena, HS_Key *key_out, Rng1U64 *range_out, String8 *path_out)
{
  OS_MutexScope(fs_shared->u2s_ring_mutex) for(;;)
  {
    U64 unconsumed_size = fs_shared->u2s_ring_write_pos - fs_shared->u2s_ring_read_pos;
    if(unconsumed_size >= sizeof(*key_out) + sizeof(U64)*2 + sizeof(U64))
    {
      fs_shared->u2s_ring_read_pos += ring_read_struct(fs_shared->u2s_ring_base, fs_shared->u2s_ring_size, fs_shared->u2s_ring_read_pos, key_out);
      fs_shared->u2s_ring_read_pos += ring_read_struct(fs_shared->u2s_ring_base, fs_shared->u2s_ring_size, fs_shared->u2s_ring_read_pos, &range_out->min);
      fs_shared->u2s_ring_read_pos += ring_read_struct(fs_shared->u2s_ring_base, fs_shared->u2s_ring_size, fs_shared->u2s_ring_read_pos, &range_out->max);
      fs_shared->u2s_ring_read_pos += ring_read_struct(fs_shared->u2s_ring_base, fs_shared->u2s_ring_size, fs_shared->u2s_ring_read_pos, &path_out->size);
      path_out->str = push_array(arena, U8, path_out->size);
      fs_shared->u2s_ring_read_pos += ring_read(fs_shared->u2s_ring_base, fs_shared->u2s_ring_size, fs_shared->u2s_ring_read_pos, path_out->str, path_out->size);
      break;
    }
    os_condition_variable_wait(fs_shared->u2s_ring_cv, fs_shared->u2s_ring_mutex, max_U64);
  }
  os_condition_variable_broadcast(fs_shared->u2s_ring_cv);
}

ASYNC_WORK_DEF(fs_stream_work)
{
  ProfBeginFunction();
  Temp scratch = scratch_begin(0, 0);
  
  //- rjf: get next request
  HS_Key key = {0};
  Rng1U64 range = {0};
  String8 path = {0};
  fs_u2s_dequeue_req(scratch.arena, &key, &range, &path);
  
  //- rjf: unpack request
  U64 path_hash = fs_little_hash_from_string(path);
  U64 path_slot_idx = path_hash%fs_shared->slots_count;
  U64 path_stripe_idx = path_slot_idx%fs_shared->stripes_count;
  FS_Slot *path_slot = &fs_shared->slots[path_slot_idx];
  FS_Stripe *path_stripe = &fs_shared->stripes[path_stripe_idx];
  
  //- rjf: load
  ProfBegin("load \"%.*s\"", str8_varg(path));
  FileProperties pre_props = os_properties_from_file_path(path);
  U64 range_size = dim_1u64(range);
  U64 read_size = Min(pre_props.size - range.min, range_size);
  OS_Handle file = os_file_open(OS_AccessFlag_Read|OS_AccessFlag_ShareRead|OS_AccessFlag_ShareWrite, path);
  B32 file_handle_is_valid = !os_handle_match(os_handle_zero(), file);
  U64 data_arena_size = read_size+ARENA_HEADER_SIZE;
  data_arena_size += KB(4)-1;
  data_arena_size -= data_arena_size%KB(4);
  ProfBegin("allocate");
  Arena *data_arena = arena_alloc(.reserve_size = data_arena_size, .commit_size = data_arena_size);
  ProfEnd();
  ProfBegin("read");
  String8 data = os_string_from_file_range(data_arena, file, r1u64(range.min, range.min+read_size));
  ProfEnd();
  os_file_close(file);
  FileProperties post_props = os_properties_from_file_path(path);
  
  //- rjf: abort if modification timestamps or sizes differ - we did not successfully read the file
  B32 read_good = (pre_props.modified == post_props.modified &&
                   pre_props.size == post_props.size &&
                   read_size == data.size &&
                   (file_handle_is_valid || pre_props.flags & FilePropertyFlag_IsFolder));
  if(!read_good)
  {
    ProfScope("abort")
    {
      arena_release(data_arena);
      MemoryZeroStruct(&data);
      data_arena = 0;
    }
  }
  
  //- rjf: submit
  else
  {
    ProfScope("submit")
    {
      hs_submit_data(key, &data_arena, data);
    }
  }
  
  //- rjf: commit info to cache
  ProfScope("commit to cache") OS_MutexScopeW(path_stripe->rw_mutex)
  {
    FS_Node *node = 0;
    for(FS_Node *n = path_slot->first; n != 0; n = n->next)
    {
      if(str8_match(n->path, path, 0))
      {
        node = n;
        break;
      }
    }
    if(node != 0 && read_good)
    {
      if(node->props.modified != 0)
      {
        ins_atomic_u64_inc_eval(&fs_shared->change_gen);
      }
      node->props = post_props;
    }
  }
  os_condition_variable_broadcast(path_stripe->cv);
  
  ProfEnd();
  scratch_end(scratch);
  ProfEnd();
  return 0;
}

////////////////////////////////
//~ rjf: Change Detector Thread

internal void
fs_detector_thread__entry_point(void *p)
{
  ThreadNameF("[fs] detector thread");
  for(;;)
  {
    U64 slots_per_stripe = fs_shared->slots_count/fs_shared->stripes_count;
    for(U64 stripe_idx = 0; stripe_idx < fs_shared->stripes_count; stripe_idx += 1)
    {
      FS_Stripe *stripe = &fs_shared->stripes[stripe_idx];
      OS_MutexScopeR(stripe->rw_mutex) for(U64 slot_in_stripe_idx = 0; slot_in_stripe_idx < slots_per_stripe; slot_in_stripe_idx += 1)
      {
        U64 slot_idx = stripe_idx*slots_per_stripe + slot_in_stripe_idx;
        FS_Slot *slot = &fs_shared->slots[slot_idx];
        for(FS_Node *n = slot->first; n != 0; n = n->next)
        {
          FileProperties props = os_properties_from_file_path(n->path);
          if(props.modified != n->props.modified)
          {
            for(U64 range_slot_idx = 0; range_slot_idx < n->slots_count; range_slot_idx += 1)
            {
              for(FS_RangeNode *range_n = n->slots[range_slot_idx].first;
                  range_n != 0;
                  range_n = range_n->next)
              {
                HS_Key key = hs_key_make(n->root, range_n->id);
                if(ins_atomic_u64_eval(&range_n->working_count) == 0 &&
                   fs_u2s_enqueue_req(key, r1u64(key.id.u128[0].u64[0], key.id.u128[0].u64[1]), n->path, os_now_microseconds()+100000))
                {
                  ins_atomic_u64_inc_eval(&range_n->working_count);
                  async_push_work(fs_stream_work, .working_counter = &range_n->working_count);
                }
              }
            }
          }
        }
      }
    }
    os_sleep_milliseconds(100);
  }
}
