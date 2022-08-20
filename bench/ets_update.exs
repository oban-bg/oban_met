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

insert_bag = fn value ->
  :ets.insert(bag, {{:count, value}, 1})
end

run_update = fn ->
  for value <- 0..1_000, do: update_set.(value)

  :ets.delete_all_objects(set)
end

run_insert = fn ->
  for value <- 0..1_000, do: insert_bag.(value)

  :ets.delete_all_objects(bag)
end

Benchee.run(%{"Update Set" => run_update, "Insert Bag" => run_insert})
