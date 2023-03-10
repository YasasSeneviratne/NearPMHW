
`timescale 1 ns / 1 ps

module axi_lite_master_pcie #(parameter C_M_START_DATA_VALUE	 = 32'hAA000000,
                              parameter C_M_TARGET_SLAVE_BASE_ADDR	 = 32'h40000000,
                              parameter integer C_M_AXI_ADDR_WIDTH	 = 32,
                              parameter integer C_M_AXI_DATA_WIDTH	 = 64,
                              parameter integer C_M_TRANSACTIONS_NUM	 = 4)
                             (input wire DMA_START,
                              input wire [31:0] DMA_SRC,
                              input wire [31:0] DMA_DEST,
                              input wire [31:0] DMA_LEN,
                              output reg DMA_DONE,
                              output [3:0] mst_exec_state,
                          //    output wire TXN_DONE,
                              input wire M_AXI_ACLK,
                              input wire M_AXI_ARESETN,
                              output wire [C_M_AXI_ADDR_WIDTH-1 : 0] M_AXI_AWADDR,
                              output wire [2 : 0] M_AXI_AWPROT,
                              output wire M_AXI_AWVALID,
                              input wire M_AXI_AWREADY,
                              output wire [C_M_AXI_DATA_WIDTH-1 : 0] M_AXI_WDATA,
                              output wire [C_M_AXI_DATA_WIDTH/8-1 : 0] M_AXI_WSTRB,
                              output wire M_AXI_WVALID,
                              input wire M_AXI_WREADY,
                              input wire [1 : 0] M_AXI_BRESP,
                              input wire M_AXI_BVALID,
                              output wire M_AXI_BREADY,
                              output wire [C_M_AXI_ADDR_WIDTH-1 : 0] M_AXI_ARADDR,
                              output wire [2 : 0] M_AXI_ARPROT,
                              output wire M_AXI_ARVALID,
                              input wire M_AXI_ARREADY,
                              input wire [C_M_AXI_DATA_WIDTH-1 : 0] M_AXI_RDATA,
                              input wire [1 : 0] M_AXI_RRESP,
                              input wire M_AXI_RVALID,
                              output wire M_AXI_RREADY);
    
    // function called clogb2 that returns an integer which has the
    // value of the ceiling of the log base 2
    
    function integer clogb2 (input integer bit_depth);
        begin
            for(clogb2 = 0; bit_depth>0; clogb2 = clogb2+1)
                bit_depth = bit_depth >> 1;
        end
    endfunction
    
    // TRANS_NUM_BITS is the width of the index counter for
    // number of write or read transaction.
    localparam integer TRANS_NUM_BITS = clogb2(C_M_TRANSACTIONS_NUM-1);
    
    //DMA configuration parameters
    localparam XAXIDMA_TX_OFFSET       = 32'h00000000;
    localparam XAXIDMA_RX_OFFSET       = 32'h00000030;
    localparam XAXIDMA_CR_OFFSET       = 32'h00000000;
    localparam XAXIDMA_SR_OFFSET       = 32'h00000004;
    localparam XAXIDMA_SRCADDR_OFFSET  = 32'h00000018;
    localparam XAXIDMA_DESTADDR_OFFSET = 32'h00000018;
    localparam XAXIDMA_CR_RUNSTOP_MASK = 32'h00000001;
    localparam XAXIDMA_BUFFLEN_OFFSET  = 32'h00000028;
    localparam XAXIDMA_HALTED_MASK     = 32'h00000001;
    localparam XAXIDMA_IDLE_MASK       = 32'h00000002;
    localparam XAXIDMA_CR_RESET_MASK   = 32'h00000004;
    
    
    /////////////////////////////////////////////
    
    
    // Example State machine to initialize counter, initialize write transactions,
    // initialize read transactions and comparison of read data with the
    // written data words.
    parameter [3:0] IDLE = 4'b0000,
    //read dma MM-S
    INIT_CHECK_TX_STATUS = 4'b0001,
    INIT_READ_SRC = 4'b0010,
    UPDATE_READ_CR_1 = 4'b0011,
    UPDATE_READ_CR_2 = 4'b0100,
    INIT_READ_LEN = 4'b0101,
    //    WAIT_READ_COMPLETE = 3'b110,
    //write dma S-MM
    INIT_CHECK_RX_STATUS = 4'b0111,
    INIT_WRITE_DEST = 4'b1000,
    UPDATE_WRITE_CR_1 = 4'b1001,
    UPDATE_WRITE_CR_2 = 4'b1010,
    INIT_WRITE_LEN = 4'b1011,
    WAIT_WRITE_COMPLETE = 4'b1100,
    RESET_DMA = 4'b1101
    ;
    
    reg [4:0] mst_exec_state;
    
    // AXI4LITE signals
    //write address valid
    reg      axi_awvalid;
    //write data valid
    reg      axi_wvalid;
    //read address valid
    reg      axi_arvalid;
    //read data acceptance
    reg      axi_rready;
    //write response acceptance
    reg      axi_bready;
    //write address
    reg [C_M_AXI_ADDR_WIDTH-1 : 0]     axi_awaddr;
    //write data
    reg [C_M_AXI_DATA_WIDTH-1 : 0]     axi_wdata;
    //read addresss
    reg [C_M_AXI_ADDR_WIDTH-1 : 0]     axi_araddr;
    //Asserts when there is a write response error
    wire      write_resp_error;
    //Asserts when there is a read response error
    wire      read_resp_error;
    //A pulse to initiate a write transaction
    reg      start_single_write;
    //A pulse to initiate a read transaction
    reg      start_single_read;
    //Asserts when a single beat write transaction is issued and remains asserted till the completion of write trasaction.
    reg      write_issued;
    //Asserts when a single beat read transaction is issued and remains asserted till the completion of read trasaction.
    reg      read_issued;
    //flag that marks the completion of write trasactions. The number of write transaction is user selected by the parameter C_M_TRANSACTIONS_NUM.
    reg      writes_done;
    //flag that marks the completion of read trasactions. The number of read transaction is user selected by the parameter C_M_TRANSACTIONS_NUM
    reg      reads_done;
    //The error register is asserted when any of the write response error, read response error or the data mismatch flags are asserted.
    reg      error_reg;
    //index counter to track the number of write transaction issued
    reg [TRANS_NUM_BITS : 0]     write_index;
    //index counter to track the number of read transaction issued
    //reg [TRANS_NUM_BITS : 0]     read_index;
    //Expected read data used to compare with the read data.
    //reg [C_M_AXI_DATA_WIDTH-1 : 0]     expected_rdata;
    //Flag marks the completion of comparison of the read data with the expected read data
 //   reg      compare_done;
    //This flag is asserted when there is a mismatch of the read data with the expected read data.
  //  reg      read_mismatch;
    //Flag is asserted when the write index reaches the last write transction number
   // reg      last_write;
    //Flag is asserted when the read index reaches the last read transction number
  //  reg      last_read;
   // reg      init_txn_ff;
   // reg      init_txn_ff2;
   // reg      init_txn_edge;
    wire      init_txn_pulse;
    
    
    // I/O Connections assignments
    
    //Adding the offset address to the base addr of the slave
    assign M_AXI_AWADDR = C_M_TARGET_SLAVE_BASE_ADDR + axi_awaddr;
    //AXI 4 write data
    assign M_AXI_WDATA   = axi_wdata;
    assign M_AXI_AWPROT  = 3'b000;
    assign M_AXI_AWVALID = axi_awvalid;
    //Write Data(W)
    assign M_AXI_WVALID = axi_wvalid;
    //Set all byte strobes in this example
    assign M_AXI_WSTRB = 4'b1111;
    //Write Response (B)
    assign M_AXI_BREADY = axi_bready;
    //Read Address (AR)
    assign M_AXI_ARADDR  = C_M_TARGET_SLAVE_BASE_ADDR + axi_araddr;
    assign M_AXI_ARVALID = axi_arvalid;
    assign M_AXI_ARPROT  = 3'b001;
    //Read and Read Response (R)
    assign M_AXI_RREADY = axi_rready;
    //Example design I/O
  //  assign TXN_DONE         = compare_done;
    assign init_txn_pulse   = DMA_START;
    
    
   
    
    
    //--------------------
    //Write Address Channel
    //--------------------
    
    // The purpose of the write address channel is to request the address and
    // command information for the entire transaction.  It is a single beat
    // of information.
    
    // Note for this example the axi_awvalid/axi_wvalid are asserted at the same
    // time, and then each is deasserted independent from each other.
    // This is a lower-performance, but simplier control scheme.
    
    // AXI VALID signals must be held active until accepted by the partner.
    
    // A data transfer is accepted by the slave when a master has
    // VALID data and the slave acknoledges it is also READY. While the master
    // is allowed to generated multiple, back-to-back requests by not
    // deasserting VALID, this design will add rest cycle for
    // simplicity.
    
    // Since only one outstanding transaction is issued by the user design,
    // there will not be a collision between a new request and an accepted
    // request on the same clock cycle.
    
    always @(posedge M_AXI_ACLK)
    begin
        //Only VALID signals must be deasserted during reset per AXI spec
        //Consider inverting then registering active-low reset for higher fmax
        if (M_AXI_ARESETN == 0 || init_txn_pulse == 1'b1)
        begin
            axi_awvalid <= 1'b0;
        end
        //Signal a new address/data command is available by user logic
        else
        begin
        if (start_single_write)
        begin
            axi_awvalid <= 1'b1;
        end
        //Address accepted by interconnect/slave (issue of M_AXI_AWREADY by slave)
        else if (M_AXI_AWREADY && axi_awvalid)
        begin
        axi_awvalid <= 1'b0;
    end
    end
    end
    
    
    // start_single_write triggers a new write
    // transaction. write_index is a counter to
    // keep track with number of write transaction
    // issued/initiated
    always @(posedge M_AXI_ACLK)
    begin
        if (M_AXI_ARESETN == 0 || init_txn_pulse == 1'b1)
        begin
            write_index <= 0;
        end
        // Signals a new write address/ write data is
        // available by user logic
        else if (start_single_write)
        begin
        write_index <= write_index + 1;
    end
    end
    
    
    //--------------------
    //Write Data Channel
    //--------------------
    
    //The write data channel is for transfering the actual data.
    //The data generation is speific to the example design, and
    //so only the WVALID/WREADY handshake is shown here
    
    always @(posedge M_AXI_ACLK)
    begin
        if (M_AXI_ARESETN == 0  || init_txn_pulse == 1'b1)
        begin
            axi_wvalid <= 1'b0;
        end
        //Signal a new address/data command is available by user logic
        else if (start_single_write)
        begin
        axi_wvalid <= 1'b1;
    end
    //Data accepted by interconnect/slave (issue of M_AXI_WREADY by slave)
    else if (M_AXI_WREADY && axi_wvalid)
    begin
    axi_wvalid <= 1'b0;
    end
    end
    
    
    //----------------------------
    //Write Response (B) Channel
    //----------------------------
    
    //The write response channel provides feedback that the write has committed
    //to memory. BREADY will occur after both the data and the write address
    //has arrived and been accepted by the slave, and can guarantee that no
    //other accesses launched afterwards will be able to be reordered before it.
    
    //The BRESP bit [1] is used indicate any errors from the interconnect or
    //slave for the entire write burst. This example will capture the error.
    
    //While not necessary per spec, it is advisable to reset READY signals in
    //case of differing reset latencies between master/slave.
    
    always @(posedge M_AXI_ACLK)
    begin
        if (M_AXI_ARESETN == 0 || init_txn_pulse == 1'b1)
        begin
            axi_bready <= 1'b0;
        end
        // accept/acknowledge bresp with axi_bready by the master
        // when M_AXI_BVALID is asserted by slave
        else if (M_AXI_BVALID && ~axi_bready)
        begin
        axi_bready <= 1'b1;
    end
    // deassert after one clock cycle
    else if (axi_bready)
    begin
    axi_bready <= 1'b0;
    end
    // retain the previous value
    else
    axi_bready <= axi_bready;
    end
    
    //Flag write errors
    assign write_resp_error = (axi_bready & M_AXI_BVALID & M_AXI_BRESP[1]);
    
    
    //----------------------------
    //Read Address Channel
    //----------------------------
    
    //start_single_read triggers a new read transaction. read_index is a counter to
    //keep track with number of read transaction issued/initiated
  /*  
    always @(posedge M_AXI_ACLK)
    begin
        if (M_AXI_ARESETN == 0 || init_txn_pulse == 1'b1)
        begin
            read_index <= 0;
        end
        // Signals a new read address is
        // available by user logic
        else if (start_single_read)
        begin
        read_index <= read_index + 1;
    end
    end
    */
    // A new axi_arvalid is asserted when there is a valid read address
    // available by the master. start_single_read triggers a new read
    // transaction
    always @(posedge M_AXI_ACLK)
    begin
        if (M_AXI_ARESETN == 0 || init_txn_pulse == 1'b1)
        begin
            axi_arvalid <= 1'b0;
        end
        //Signal a new read address command is available by user logic
        else if (start_single_read)
        begin
        axi_arvalid <= 1'b1;
    end
    //RAddress accepted by interconnect/slave (issue of M_AXI_ARREADY by slave)
    else if (M_AXI_ARREADY && axi_arvalid)
    begin
    axi_arvalid <= 1'b0;
    end
    // retain the previous value
    end
    
    
    //--------------------------------
    //Read Data (and Response) Channel
    //--------------------------------
    
    //The Read Data channel returns the results of the read request
    //The master will accept the read data by asserting axi_rready
    //when there is a valid read data available.
    //While not necessary per spec, it is advisable to reset READY signals in
    //case of differing reset latencies between master/slave.
    
    always @(posedge M_AXI_ACLK)
    begin
        if (M_AXI_ARESETN == 0 || init_txn_pulse == 1'b1)
        begin
            axi_rready <= 1'b0;
        end
        // accept/acknowledge rdata/rresp with axi_rready by the master
        // when M_AXI_RVALID is asserted by slave
        else if (M_AXI_RVALID && ~axi_rready)
        begin
        axi_rready <= 1'b1;
    end
    // deassert after one clock cycle
    else if (axi_rready)
    begin
    axi_rready <= 1'b0;
    end
    // retain the previous value
    end
    
    //Flag write errors
    assign read_resp_error = (axi_rready & M_AXI_RVALID & M_AXI_RRESP[1]);
    
    
    //--------------------------------
    //User Logic
    //--------------------------------
    
    //Address/Data Stimulus
    reg [C_M_AXI_ADDR_WIDTH-1:0] waddr;
    reg [C_M_AXI_DATA_WIDTH-1:0] wdata;
    reg [C_M_AXI_ADDR_WIDTH-1:0] raddr;
    reg [C_M_AXI_DATA_WIDTH-1:0] rdata;
    //Address/data pairs for this example. The read and write values should
    //match.
    //Modify these as desired for different address patterns.
    
    //Write Addresses
    always @(posedge M_AXI_ACLK)
    begin
        if (M_AXI_ARESETN == 0  || init_txn_pulse == 1'b1)
        begin
            axi_awaddr <= 0;
        end
        // Signals a new write address/ write data is
        // available by user logic
        else //if (M_AXI_AWREADY && axi_awvalid)
        begin
        axi_awaddr <= waddr;//axi_awaddr + 32'h00000004;
        
    end
    end
    
    // Write data generation
    always @(posedge M_AXI_ACLK)
    begin
        if (M_AXI_ARESETN == 0 || init_txn_pulse == 1'b1)
        begin
            axi_wdata <= 32'd0;//C_M_START_DATA_VALUE;
        end
        // Signals a new write address/ write data is
        // available by user logic
        else //if (M_AXI_WREADY && axi_wvalid)
        begin
        axi_wdata <= wdata;//C_M_START_DATA_VALUE + write_index;
    end
    end
    
    //Read Addresses
    always @(posedge M_AXI_ACLK)
    begin
        if (M_AXI_ARESETN == 0  || init_txn_pulse == 1'b1)
        begin
            axi_araddr <= 0;
        end
        // Signals a new write address/ write data is
        // available by user logic
        else //if (M_AXI_ARREADY && axi_arvalid)
        begin
        axi_araddr <= raddr;//axi_araddr + 32'h00000004;
    end
    end
    
 
    // TASKS to make life easiier
    task axi_issue_write;
    input [C_M_AXI_ADDR_WIDTH-1:0] address;
    input [C_M_AXI_DATA_WIDTH-1:0] data;
    begin                            
        if (~axi_awvalid && ~axi_wvalid && ~M_AXI_BVALID &&  ~start_single_write && ~write_issued)
        begin
            start_single_write <= 1'b1;
            write_issued       <= 1'b1;
            waddr              <= address;
            wdata <= data;
        end
        else if (axi_bready)
        begin
            write_issued <= 1'b0;
        end
        else
        begin
            start_single_write <= 1'b0; //Negate to generate a pulse
        end
    end
    endtask
    
    task axi_issue_read;
    input [31:0] address;
    begin
        if (~axi_arvalid && ~M_AXI_RVALID && ~start_single_read && ~read_issued)
        begin
            start_single_read <= 1'b1;
            read_issued       <= 1'b1;
            raddr             <= address;
        end
        else if (axi_rready)
        begin
            read_issued <= 1'b0;
        end
        else
        begin
            start_single_read <= 1'b0; //Negate to generate a pulse
        end
    end
    endtask
    
    
    ////////////// end of tasks
    

        //implement MM-steam command interface state machine
        localparam thread1 = 32'h0100_0000;
	    localparam thread2 = 32'h0200_0000;
            always @ (posedge M_AXI_ACLK)
            begin
                if (M_AXI_ARESETN == 1'b0)
                begin
                    // reset condition
                    // All the signals are assigned default values under reset condition
                    mst_exec_state     <= IDLE;
                    start_single_write <= 1'b0;
                    write_issued       <= 1'b0;
                    waddr              <= 32'd0;
                    raddr              <= 32'd0;
                    wdata              <= 32'd0;
                    DMA_DONE           <= 1'b0;
                    start_single_read  <= 1'b0;
                    read_issued        <= 1'b0;
                end
                else
                begin
                    // state transition
                    case (mst_exec_state)
                        
                        IDLE:
                        // This state is responsible to initiate
                        // AXI transaction when init_txn_pulse is asserted
                        begin
                            DMA_DONE <= 1'b0;
                            if (init_txn_pulse == 1'b1)
                            begin
                                mst_exec_state <= 5'b0001;
                            end
                            else
                            begin
                                mst_exec_state <= IDLE;
                            end
                        end
                        5'b00001:
                    	if (writes_done)
                        begin
                            mst_exec_state <= 5'b00010;
                        end
                        else
                        begin
                            
                            mst_exec_state <= 5'b00001;
                            
                            axi_issue_write( XAXIDMA_TX_OFFSET + XAXIDMA_SRCADDR_OFFSET,  64'hdeadbeefdeadbeef);
                        end
                        5'b00010:
                    	if (writes_done)
                        begin
                            mst_exec_state <= 5'b00011;
                        end
                        else
                        begin
                            
                            mst_exec_state <= 5'b00010;
                            
                            axi_issue_write( XAXIDMA_TX_OFFSET + XAXIDMA_SRCADDR_OFFSET,  64'hffafabcdefab1234);
                        end
                        5'b00011:
                    	if (writes_done)
                        begin
                            mst_exec_state <= 5'b00100;
                        end
                        else
                        begin
                            
                            mst_exec_state <= 5'b00011;
                            
                            axi_issue_write( XAXIDMA_TX_OFFSET + XAXIDMA_SRCADDR_OFFSET,  64'h0000000000000013);
                        end
                        5'b00100:
                    	if (writes_done)
                        begin
                            mst_exec_state <= 5'b00101;
                        end
                        else
                        begin
                            
                            mst_exec_state <= 5'b00100;
                            
                            axi_issue_write( XAXIDMA_TX_OFFSET + XAXIDMA_SRCADDR_OFFSET,  64'hdeadbeefdeadbeef);
                        end
                        5'b00101:
                    	if (writes_done)
                        begin
                            mst_exec_state <= 5'b00110;
                        end
                        else
                        begin
                            
                            mst_exec_state <= 5'b00101;
                            
                            axi_issue_write( XAXIDMA_TX_OFFSET + XAXIDMA_SRCADDR_OFFSET,  64'h3425efffafdeadbe);
                        end
                        5'b00110:
                    	if (writes_done)
                        begin
                            mst_exec_state <= 5'b00000;
                        end
                        else
                        begin
                            
                            mst_exec_state <= 5'b00110;
                            
                            axi_issue_write( XAXIDMA_TX_OFFSET + XAXIDMA_SRCADDR_OFFSET,  64'h0000000000000024);
                        end
                        default :
                        begin
                            mst_exec_state <= IDLE;
                        end
                    endcase
                end
            end 
            
            
         
            
            always @(posedge M_AXI_ACLK)
            begin
                if (M_AXI_ARESETN == 0 || init_txn_pulse == 1'b1)
                    writes_done <= 1'b0;
                
                //The writes_done should be associated with a bready response
                //else if (last_write && M_AXI_BVALID && axi_bready)
                else if (M_AXI_BVALID && axi_bready)
                writes_done <= 1'b1;
                else
                writes_done <= 1'b0;//writes_done;
            end
            
            //------------------
            //Read example
            //------------------
            
            //Terminal Read Count
            /*
            always @(posedge M_AXI_ACLK)
            begin
                if (M_AXI_ARESETN == 0 || init_txn_pulse == 1'b1)
                    last_read <= 1'b0;
                
                //The last read should be associated with a read address ready response
                else if ((read_index == C_M_TRANSACTIONS_NUM) && (M_AXI_ARREADY))
                last_read <= 1'b1;
                else
                last_read <= last_read;
            end
            */
            /*
             Check for last read completion.
             
             This logic is to qualify the last read count with the final read
             response/data.
             */
            always @(posedge M_AXI_ACLK)
            begin
                if (M_AXI_ARESETN == 0 || init_txn_pulse == 1'b1)begin
                    reads_done <= 1'b0;
                    rdata      <= 32'd0;
                end
                //The reads_done should be associated with a read ready response
                //else if (last_read && M_AXI_RVALID && axi_rready)
                else if (M_AXI_RVALID && axi_rready) begin
                reads_done <= 1'b1;
                rdata      <= M_AXI_RDATA;
            end
            else
            reads_done <= 1'b0;//reads_done;
        end
        
        //-----------------------------
        //Example design error register
        //-----------------------------
 /*       
        //Data Comparison
        always @(posedge M_AXI_ACLK)
        begin
            if (M_AXI_ARESETN == 0  || init_txn_pulse == 1'b1)
                read_mismatch <= 1'b0;
            
            //The read data when available (on axi_rready) is compared with the expected data
            else if ((M_AXI_RVALID && axi_rready) && (M_AXI_RDATA != expected_rdata))
            read_mismatch <= 1'b1;
            else
            read_mismatch <= read_mismatch;
        end
        
        // Register and hold any data mismatches, or read/write interface errors
        always @(posedge M_AXI_ACLK)
        begin
            if (M_AXI_ARESETN == 0  || init_txn_pulse == 1'b1)
                error_reg <= 1'b0;
            
            //Capture any error types
            else if (read_mismatch || write_resp_error || read_resp_error)
            error_reg <= 1'b1;
            else
            error_reg <= error_reg;
        end
        
        */
        // Add user logic here
        
        // User logic ends
        endmodule
