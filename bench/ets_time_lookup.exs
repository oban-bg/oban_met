name_bag = :ets.new(:bag, [:bag, :public])
labl_bag = :ets.new(:bag, [:bag, :public])

time = System.system_time(:second)

for _ <- 1..10_000 do
  :ets.insert(name_bag, {:available, time - 300, time, 1, %{queue: "default"}})
  :ets.insert(labl_bag, {%{name: :available, queue: "default"}, time - 300, time, 1})
end

Benchee.run(%{
  "Name Key" => fn ->
    :ets.select(
      name_bag,
      [
        {{:available, :"$1", :"$2", :"$3", :"$4"},
         [{:andalso, {:>, :"$1", time - 10}, {:<, :"$2", time}}], [{{:"$3", :"$4"}}]}
      ]
    )
  end,
  "Label Key" => fn ->
    :ets.select(labl_bag, [
      {{:"$1", :"$2", :"$3", :"$4"},
       [
         {:andalso,
          {:andalso, {:==, {:map_get, :name, :"$1"}, :available}, {:>, :"$2", time - 10}},
          {:<, :"$3", time}}
       ], [{{:"$1", :"$4"}}]}
    ])
  end
})
