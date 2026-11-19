// Passive, simulation-only full-network profiling. Never drives DUT signals.
// Exclusive accounting order is deliberate; occupancy counters may overlap it.
bit profile_enabled=0;
string profile_file,phase_file;
logic [3:0] phase_map[0:65535];
integer profile_phase=0,category,owner,profile_fd;
longint partition[0:8]='{default:0};
longint phase_partition[0:9][0:8]='{default:'{default:0}};
longint occupancy[0:5]='{default:0}; // dma, micro, exec, data, bus-data, bus-fetch
longint qpi_states[0:1][0:7]='{default:'{default:0}};
longint requests[0:1]='{default:0},payload_bytes[0:1]='{default:0};
longint micro_states[0:31]='{default:0};
longint micro_control_states[0:31]='{default:0};
longint dma_states[0:4]='{default:0};
longint mem_states[0:8]='{default:0};
longint exec_states[0:3]='{default:0};
longint sram_reads=0,sram_writes=0,sram_accumulates=0,dma_runs=0,weight_dma_runs=0;
longint execute_count=0,host_instructions=0,core_instructions=0,skipped_columns=0,active_columns=0;
longint front_cycles=0,completion_cycles=0,profile_program_cycles=0;
bit program_seen=0;
initial begin
    profile_enabled=$value$plusargs("PROFILE=%s",profile_file);
    if(profile_enabled)begin
        if(!$value$plusargs("PHASES=%s",phase_file))$fatal(1,"profile needs PHASES");
        $readmemh(phase_file,phase_map);
    end
end
always @(posedge bench.clk)if(profile_enabled && measuring)begin
    if(bench.dut.frontend.state>=6)begin
        program_seen=1;profile_program_cycles++;
        if(bench.dut.inst_val && bench.dut.decoder_rdy)begin
            profile_phase=int'(phase_map[(bench.dut.frontend.pc-program_base)>>1]);
            host_instructions++;
        end
        if(profile_phase>9)$fatal(1,"invalid phase");
        // One bucket per cycle. DMA occupies the dispatch path for its entire run.
        if(bench.dut.dma_busy)category=bench.dut.itf.state>=3 ? 1 : 0;
        else if(bench.dut.itf.state>=3)category=bench.dut.itf.saved_write && bench.dut.itf.saved_accumulate ? 2 : 3;
        else if(bench.dut.itf.state!=0)category=4;
        else if(!bench.dut.exec_rdy)category=5;
        else if(bench.dut.micro_busy)category=6;
        else if(bench.dut.frontend.state==7 || bench.dut.frontend.state==8)category=7;
        else category=8;
        partition[category]++;phase_partition[profile_phase][category]++;
        if(category==6)micro_control_states[bench.dut.sequencer.state]++;
        if(bench.dut.dma_busy)occupancy[0]++;
        if(bench.dut.micro_busy)occupancy[1]++;
        if(!bench.dut.exec_rdy)occupancy[2]++;
        if(!bench.dut.data_rdy)occupancy[3]++;
        if(bench.dut.bus_busy)occupancy[bench.dut.memory_owner.owner_fetch ? 5 : 4]++;
        if(bench.dut.serial_memory.state!=0)
            qpi_states[bench.dut.memory_owner.owner_fetch][bench.dut.serial_memory.state]++;
        if(bench.dut.bus_valid && bench.dut.bus_ready)begin
            owner=bench.dut.fetch_valid && bench.dut.fetch_ready;
            requests[owner]++;payload_bytes[owner]+=bench.dut.bus_bytes;
        end
        micro_states[bench.dut.sequencer.state]++;
        dma_states[bench.dut.dma.state]++;
        mem_states[bench.dut.itf.state]++;
        exec_states[bench.dut.exec.state]++;
        if(bench.dut.mem_rdy && (bench.dut.itf.read_en || bench.dut.itf.write_en) && bench.dut.itf.device==1)begin
            if(bench.dut.itf.read_en)sram_reads++;
            else if(bench.dut.itf.write_accumulate)sram_accumulates++;
            else sram_writes++;
        end
        if(bench.dut.sequenced_valid && bench.dut.sequenced_ready && bench.dut.sequenced_inst[15:10]==6'b110010 && bench.dut.sequenced_inst[7:0]!=0)begin
            dma_runs++;
            if(bench.dut.micro_busy)weight_dma_runs++;
        end
        if(bench.dut.exec_inst_val && bench.dut.exec_rdy)execute_count++;
        if(bench.dut.dispatched_valid && bench.dut.dispatched_ready)core_instructions++;
        // Current benchmark is batch 1. Count decisions, not mask/column time.
        if(bench.dut.sequencer.state==6 && bench.dut.sequencer.batch_size==1)begin
            if(bench.dut.sequencer.sparse && bench.dut.loaded_input_zero_mask[bench.dut.sequencer.cur])skipped_columns++;
            else active_columns++;
        end
    end else if(program_seen)completion_cycles++;
    else front_cycles++;
end

task dump_profile;
    longint total;
    total=0;for(int i=0;i<9;i++)total+=partition[i];
    if(total!=core_cycles || profile_program_cycles!=core_cycles || front_cycles+core_cycles+completion_cycles!=cycles)
        $fatal(1,"profile partition mismatch");
    profile_fd=$fopen(profile_file,"w");
    $fwrite(profile_fd,"{\"program_cycles\":%0d,\"front_cycles\":%0d,\"completion_cycles\":%0d,\"partition\":[",profile_program_cycles,front_cycles,completion_cycles);
    for(int i=0;i<9;i++)$fwrite(profile_fd,"%s%0d",i==0?"":",",partition[i]);
    $fwrite(profile_fd,"],\"phases\":[");
    for(int p=0;p<10;p++)begin
        $fwrite(profile_fd,"%s[",p==0?"":",");
        for(int i=0;i<9;i++)$fwrite(profile_fd,"%s%0d",i==0?"":",",phase_partition[p][i]);
        $fwrite(profile_fd,"]");
    end
    $fwrite(profile_fd,"],\"occupancy\":[");
    for(int i=0;i<6;i++)$fwrite(profile_fd,"%s%0d",i==0?"":",",occupancy[i]);
    $fwrite(profile_fd,"],\"qpi_states\":[");
    for(int p=0;p<2;p++)begin
        $fwrite(profile_fd,"%s[",p==0?"":",");
        for(int i=0;i<8;i++)$fwrite(profile_fd,"%s%0d",i==0?"":",",qpi_states[p][i]);
        $fwrite(profile_fd,"]");
    end
    $fwrite(profile_fd,"],\"requests\":[%0d,%0d],\"payload_bytes\":[%0d,%0d],",requests[0],requests[1],payload_bytes[0],payload_bytes[1]);
    $fwrite(profile_fd,"\"micro_states\":[");for(int i=0;i<32;i++)$fwrite(profile_fd,"%s%0d",i==0?"":",",micro_states[i]);
    $fwrite(profile_fd,"],\"micro_control_states\":[");for(int i=0;i<32;i++)$fwrite(profile_fd,"%s%0d",i==0?"":",",micro_control_states[i]);
    $fwrite(profile_fd,"],\"dma_states\":[");for(int i=0;i<5;i++)$fwrite(profile_fd,"%s%0d",i==0?"":",",dma_states[i]);
    $fwrite(profile_fd,"],\"mem_states\":[");for(int i=0;i<9;i++)$fwrite(profile_fd,"%s%0d",i==0?"":",",mem_states[i]);
    $fwrite(profile_fd,"],\"exec_states\":[");for(int i=0;i<4;i++)$fwrite(profile_fd,"%s%0d",i==0?"":",",exec_states[i]);
    $fwrite(profile_fd,"],\"sram_reads\":%0d,\"sram_writes\":%0d,\"sram_accumulates\":%0d,\"dma_runs\":%0d,\"weight_dma_runs\":%0d,\"execute_count\":%0d,\"host_instructions\":%0d,\"core_instructions\":%0d,\"skipped_columns\":%0d,\"active_columns\":%0d}\n",sram_reads,sram_writes,sram_accumulates,dma_runs,weight_dma_runs,execute_count,host_instructions,core_instructions,skipped_columns,active_columns);
    $fclose(profile_fd);
endtask
