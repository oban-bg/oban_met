set = :ets.new(:bench_set, [:set, :public])
bag = :ets.new(:bench_bag, [:duplicate_bag, :public])

update_set = fn value ->
  key = {:count, value}

  case :ets.lookup(set, key) do
    [{^key, count}] ->
      :ets.insert(set, {key, count + 1})

    [] ->
      :ets.insert(set, {key, 1})
  end
end

update_cnt = fn value ->
  key = {:delta, value}

  :ets.update_counter(set, key, {2, 1}, {key, 0})
end

insert_bag = fn value ->
  :ets.insert(bag, {{:count, value}, 1})
end

run_update_set = fn ->
  for value <- 0..1_000, do: update_set.(value)

  :ets.delete_all_objects(set)
end

run_update_cnt = fn ->
  for value <- 0..1_000, do: update_cnt.(value)

  :ets.delete_all_objects(set)
end

run_insert = fn ->
  for value <- 0..1_000, do: insert_bag.(value)

  :ets.delete_all_objects(bag)
end

Benchee.run(%{
  "Update Set" => run_update_set,
  "Update Count" => run_update_cnt,
  "Insert Bag" => run_insert
})
