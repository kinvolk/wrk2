-- example reporting script which demonstrates a custom
-- done() function that prints results as JSON

done = function(summary, latency, requests)
    --  io.write("\nJSON Output:\n")
      io.write("{\n")
      io.write(string.format("\t\"requests\": %d,\n", summary.requests))
      io.write(string.format("\t\"duration_in_microseconds\": %0.2f,\n", summary.duration))
      io.write(string.format("\t\"bytes\": %d,\n", summary.bytes))
      io.write(string.format("\t\"requests_per_sec\": %0.2f,\n", (summary.requests/summary.duration)*1e6))
      io.write(string.format("\t\"bytes_transfer_per_sec\": %0.2f,\n", (summary.bytes/summary.duration)*1e6))
      io.write(string.format("\t Min: %0.2f,\n", latency.min))
      io.write(string.format("\t Avg: %0.2f,\n", latency.mean))
      io.write(string.format("\t Max: %0.2f,\n", latency.max))
      io.write(string.format("\t StdDev: %0.2f,\n", latency.stdev))
  
      
      -- print(string.format("Total Requests: %d", summary.requests))
      -- print(string.format("HTTP errors: %d", summary.errors.status))
      -- print(string.format("Requests timed out: %d", summary.errors.timeout)) 
      -- print(string.format("Bytes received: %d", summary.bytes))
      -- print(string.format("Socket connect errors: %d", summary.errors.connect))
      -- print(string.format("Socket read errors: %d", summary.errors.read))
      -- print(string.format("Socket write errors: %d", summary.errors.write))
   
      io.write("\t\"Percentiles\": [\n")
      for _, p in pairs({ 50, 75, 90, 99, 99.9, 99.99, 99.999, 100 }) do
         io.write("\t\t{\n")
         --print(latency.total_count(50))
         n = latency:percentile(p)
        -- k = latency:total_count(p)
       -- io.write(string.format("\t\t\t\"SAKOO\": %s,\n", latency:percentile(p)))
  
         io.write(string.format("Percent: %g,\nValue: %f\n", p, n*0.001))
         if p == 100 then 
             io.write("\t\t}\n")
         else 
             io.write("\t\t},\n")
         end
      end
      io.write("\t]\n}\n")
   end