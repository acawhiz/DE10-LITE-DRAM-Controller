`timescale 10ns/1ns 
//Author: Andrew Boelbaai
//Email:acawhiz@gmail.com
//Date 2020-MAy
//Version 1.1.0
//Language:Verilog
//Target SDRAM IS42S16320F-7TL
//DATASHEET: http://www.issi.com/WW/pdf/42-45R-S_86400D-16320D-32160D.pdf
//PLATFORM DE10-LITE

module SDRAM_CTRL(

	input		    				RE,		//read request
	input		    				WR,		//write request
	input		    [24:0]		ADDR,
	output	 	 oRD_DATA_READY,
	output		 RD_REQUEST_APPROVED,
	output 		 WR_REQUEST_APPROVED,
	output  	reg	    [15:0]		RD_DATA,
	input				[15:0] WR_DATA,
	
	//////////// CLOCK //////////
	input 		          		MAX10_CLK1_100,		//state machine clock
	input 		          		MAX10_CLK2_100_3ns, 	//DRAM clock -3ns phase
	//////////// SDRAM //////////
	output		    [12:0]		DRAM_ADDR,
	output		     [1:0]		DRAM_BA,
	output		          		DRAM_CAS_N,
	output		          		DRAM_CKE,
	output		          		DRAM_CLK,
	output		          		DRAM_CS_N,
	inout 		    [15:0]		DRAM_DQ,
	output		          		DRAM_LDQM,
	output		          		DRAM_RAS_N,
	output		          		DRAM_UDQM,
	output		          		DRAM_WE_N,
	
	input 		          		reset_n,

	//////////// LED //////////
	output		     [4:0]		LEDR// state machine state indicator
	);
	

//reg [15:0]  READ_DATA;

//parameter      DATA_W             =     16;
parameter 		POWERUP_DELAY = 10000;	//100us  datasheet page 21
	
parameter      REFRESH_CYCLE             	=     14'd8192;	//datasheet page 7	
parameter      REFRESH_64ms_COUNT      	=	23'd6400000;	//@100MHz.  datasheet page 17
parameter      REFRESH_CYCLE_PULSE_WIDTH  =  23'd6399930;	//ns. Anounces refresh cycle 70 clock periods earlier so the event is not missed. FYI 70 is too much 
//parameter      ADDR_W             =     25;

///////////////command bits order:  ras_n cas_n we_n///////////////////

parameter [2:0] CMD_LOADMODE  		= 3'b000;	//datasheet page 8
parameter [2:0] CMD_AUTO_REFRESH    = 3'b001;
parameter [2:0] CMD_PRECHARGE 		= 3'b010;
parameter [2:0] CMD_ACTIVE    		= 3'b011;
parameter [2:0] CMD_WRITE     		= 3'b100;
parameter [2:0] CMD_READ      		= 3'b101;
parameter [2:0] CMD_NOP       		= 3'b111;

wire [2:0] CMD;//used to concatonate command bits above. easier to handle

////////end command/////////////////////

reg RD_DATA_READY=1'b0;//indicate when read data is available. Not valuable after all.

///////////////////state start//////////
parameter
reset_state=5'b11111,//all status leds will be on during reset.
Init_NOP_state =5'b00001,
Init_PALL_state=5'b00010,
Init_Auto_Refresh_state =5'b00011,
Init_Load_mode_register_state=5'b00100,
Init_Load_mode_register_NOP_state=5'b00101,
idle_state=5'b00110,//status leds will mostly in this state #6. 
activate_state=5'b00111,
activate_NOP_state=5'b01000,
read_state=5'b01001,
NOP_read_state1=5'b01010,
NOP_read_state2=5'b01011,
Precharge_state=5'b01100,
Precharge_NOP_state=5'b01101,
Auto_Refresh_64ms_state=5'b01110,
Init_Auto_Refresh_NOP1_state=5'b01111,
Init_Auto_Refresh_NOP2_state=5'b10000,
Init_Auto_Refresh_NOP3_state=5'b10001,
Init_Auto_Refresh_NOP4_state=5'b10010,
Init_Auto_Refresh_NOP5_state=5'b10011,
Init_Auto_Refresh_NOP6_state=5'b10100,
Init_PALL_state_NOP1_state=5'b10101,//21  numbers to help during modelsim status id
Auto_Refresh_NOP1_state=5'b10110,
Auto_Refresh_NOP2_state=5'b10111,
Auto_Refresh_NOP3_state=5'b11000,
Auto_Refresh_NOP4_state=5'b11001,
Auto_Refresh_NOP5_state=5'b11010,
Auto_Refresh_NOP6_state=5'b11011,
write_state=5'b11100,//28
NOP_write_state1=5'b11101,//29
NOP_write_state2=5'b11110;//30
/////end state/////////////

parameter [14:0] MODE_REG = 15'b00000_1_00_010_0_000; //Datasheet page 24
parameter      AUTO_REFRESH_INIT  =      8;//can be at least 2.see datasheet page 21. choose to leve at 8 due to old datasheet provided by the kit CD


reg[4:0] current_state  /* synthesis syn_preserve = 1 */;

integer count_init_powerup_delay;		//100us  datasheet page 21
reg powerup_complete_flag =1'b0;
reg[3:0] count_auto_refresh_init=4'd0;
reg[13:0] count_auto_refresh=14'd0;		//1 to 8192 refresh counter.datasheet page 7
reg[22:0] refresh_count_timer=23'd0;	//used to count 64ms interval

reg refresh_flag = 1'b0;
reg refresh_ack_flag =1'b0;

reg read_flag_ack=1'b0;			// latches to perform read operation
reg write_flag_ack=1'b0;		// latches to perform write operation


always @(posedge MAX10_CLK1_100)//Autorefresh flag every 64ms. Does not wait on reset

		begin
				
					if(refresh_count_timer < REFRESH_64ms_COUNT)
						begin
							refresh_count_timer <=refresh_count_timer+1;
							if( (refresh_count_timer > REFRESH_CYCLE_PULSE_WIDTH))
								begin
									refresh_flag <=1'b1;//Announcing refresh cycle is nearing every 64ms
								end
							else
								refresh_flag<=1'b0;
						end
					else
						begin
							refresh_count_timer <=23'd1;//restart 64ms count 
							refresh_flag<=1'b0;
						end
	
		end
		
always @(posedge MAX10_CLK1_100)//100us power up delay. Datasheet page 20-initialisation, page 21

		begin
				if( current_state==Init_NOP_state)
					begin
						
						if (count_init_powerup_delay<POWERUP_DELAY-2)//100 us
							begin
								powerup_complete_flag =1'b0;
								count_init_powerup_delay = count_init_powerup_delay + 1;
							end
						else
							powerup_complete_flag =1'b1;
							
					end
				else
					count_init_powerup_delay=0;
		end
					
always @(posedge MAX10_CLK1_100)//start of state machine
		begin
			
			if(!reset_n)	//nothing hapening here. just keeping the state machine from starting.		
							current_state=reset_state;
				else
					begin
							
							case (current_state)
								  
								  reset_state:
								  begin
										refresh_ack_flag=1'b0;
										RD_DATA_READY<=1'b0;
										count_auto_refresh_init=4'd0;
										current_state=Init_NOP_state;
									end
								  
								  Init_NOP_state:	//Powerup. Datasheet page 21
								  begin
									  			
												if (powerup_complete_flag==1'b1)//After 100us get ready to pre-charge.Datasheet page 21
													begin
														current_state=Init_PALL_state;
													end
												else
													current_state=Init_NOP_state;//waiting for 100us to pass
																  
								  end
								  			  
								  Init_PALL_state:
								  begin
											current_state=Init_PALL_state_NOP1_state;
																	  
								  end
								  
								  Init_PALL_state_NOP1_state://TRP is 15ns so two NOP cycle. 1 cycle is 10ns@100Mhz
								  begin
										current_state=Init_Auto_Refresh_state;
								  end
								  
								  Init_Auto_Refresh_state://CBR Auto-Refresh (REF)	at least 2 times.Datasheet page 21. This loop can be improved for clarity.   
								  begin
											count_auto_refresh_init<=count_auto_refresh_init+1;
											current_state=Init_Auto_Refresh_NOP1_state;
								  end
									
									Init_Auto_Refresh_NOP1_state:		//6 NOP's to meet tRC of 60ns.Datasheet page 21.
									begin
										current_state=Init_Auto_Refresh_NOP2_state;
									end
	
									Init_Auto_Refresh_NOP2_state:
									begin
										current_state=Init_Auto_Refresh_NOP3_state;
									end

									Init_Auto_Refresh_NOP3_state:
									begin
										current_state=Init_Auto_Refresh_NOP4_state;
									end
	
									Init_Auto_Refresh_NOP4_state:
									begin
										current_state=Init_Auto_Refresh_NOP5_state;
													
									end
									
									Init_Auto_Refresh_NOP5_state:
									begin
										current_state=Init_Auto_Refresh_NOP6_state;
													
									end
									
								  Init_Auto_Refresh_NOP6_state:
									begin
											if (count_auto_refresh_init < AUTO_REFRESH_INIT) 
												current_state=Init_Auto_Refresh_state;
											else
												current_state=Init_Load_mode_register_state;
									end
									
									Init_Load_mode_register_state:
									begin
											current_state=Init_Load_mode_register_NOP_state;
									end

									Init_Load_mode_register_NOP_state:
									begin
											current_state=idle_state;	//initialisation done. Now lets wait for commands.Datasheet page 14.
									end

								  idle_state:
										begin	
												
												
												if(refresh_flag && !refresh_ack_flag)						//1st priority is auto refresh
													begin
														refresh_ack_flag<=1'b1;
														current_state=Auto_Refresh_64ms_state;			// jump to auto-refresh if flagged
														
													end
												else if(!RE && read_flag_ack)//detect end of read pulse (negedge) //2nd priority is read
													begin
														read_flag_ack=1'b0;
														RD_DATA_READY<=1'b0;//disable data ready
													end
												else if(RE && !read_flag_ack)//detect start of new read pulse (posedge)
													begin
														read_flag_ack<=1'b1;		//turn read flag on so activate state can jump to read state
														current_state=activate_state;
													end
													
												else if(!WR && write_flag_ack)//detect end of write pulse (negedge)  //3rd priority is read
													begin
														write_flag_ack=1'b0;
													end
												else if(WR && !write_flag_ack)//detect start of new write pulse (posedge)
													begin
														write_flag_ack<=1'b1;	//turn write flag on so activate state can jump to write state
														current_state=activate_state;
													end

										 end	 
			
								  activate_state:
									begin
										current_state=activate_NOP_state;
									end
									
									activate_NOP_state: 			//One NOP to meet tRCD of 15ns. Datasheet page 17,27,35
										begin
											if(read_flag_ack)	
												begin

													current_state=read_state;		//after NOP jump to read state
												end
											else if(write_flag_ack)
												begin
													
													current_state=write_state;	//after NOP jump to write state
												end
											
											
											
										end								 
								  read_state:
									begin
											current_state=NOP_read_state1;
										end
									NOP_read_state1://CAS_LATENCY = 1 of 2 tick.Datasheet page 28,37
										begin
											 current_state=NOP_read_state2;
										end
									NOP_read_state2://CAS_LATENCY = 2 of 2 tick
										begin					  
												//\\//\\RD_DATA_READY<=1'b1;			//indicate that read data is available at next NOP stage on DQ
												
												current_state=Precharge_state; //Next is precharge.Because I did read without precharge. Datasheet page 37
										end
								//////////////////write state/////////////
								
								write_state:
									begin
										current_state=NOP_write_state1;
									end
									NOP_write_state1://CAS_LATENCY = 1 of 2 tick
										begin
											
											current_state=NOP_write_state2;
										end
									NOP_write_state2://2 NOP's needed to meet tdpl 14ns. Datasheet page 17,38,40
										begin
											
											current_state=Precharge_state;
										end
								
																
								  Precharge_state:
									begin
										current_state=Precharge_NOP_state;
									end
									Precharge_NOP_state:// tRP 15ns is required between precharge and activate. 1 NOP plus idle state meets tRP.  Datasheet page 52.
										begin
											current_state=idle_state;
										end
///////////////////////////CRB AUTO REFRESH 64 ms///////////////////////////////////////////

								Auto_Refresh_64ms_state://CBR Auto-Refresh (REF). Datasheet page 22	
										  begin
												 
												count_auto_refresh<=count_auto_refresh+1;
												current_state=Auto_Refresh_NOP1_state;
										  end
									
									Auto_Refresh_NOP1_state:				// Datasheet page 22. Nops required to meet tRC 60ns. I made it 70ns to be safe.
									begin
											 
											current_state=Auto_Refresh_NOP2_state;
									end
																		
									Auto_Refresh_NOP2_state:
									begin
										current_state=Auto_Refresh_NOP3_state;
									end
									
									
									Auto_Refresh_NOP3_state:
									begin
										current_state=Auto_Refresh_NOP4_state;
									end
									
									
									Auto_Refresh_NOP4_state:
									begin
										current_state=Auto_Refresh_NOP5_state;
													
									end
									
									Auto_Refresh_NOP5_state:
									begin
										current_state=Auto_Refresh_NOP6_state;
													
									end
									
								  Auto_Refresh_NOP6_state:			 
									begin
										 
										if (count_auto_refresh<REFRESH_CYCLE) 
											current_state=Auto_Refresh_64ms_state;
										else begin
												count_auto_refresh=14'd0;
												refresh_ack_flag<=1'b0;
												current_state=idle_state;
											end
									end
//////////////////////////END CBR AUTO REFRESH 64 ms/////////////////////////////////////////
									
								default : current_state<=reset_state;
							endcase
					end//else		
						
end //always

//<-DRAM clock is used here to get read data from DRAM_DQ.This clock is 3ns late to meet setup time. 
//If you ue the state machine clock it will e reading FFFF
always @(posedge MAX10_CLK2_100_3ns)//<-DRAM clock
begin
	if((current_state==NOP_read_state2 /*| current_state==Precharge_state | current_state==Precharge_NOP_state | current_state==idle_state) && RD_DATA_READY==1'b1*/))// stretching the data ready pulse till idle state. good for slow interface to still detect pulse. can be mde shorter to save one clock cycle for next read/write request
		begin
			RD_DATA<=DRAM_DQ;
 
		end
	 
end

assign oRD_DATA_READY = (/*current_state==NOP_read_state2|*/  current_state==Precharge_state | current_state==Precharge_NOP_state | current_state==idle_state)?1'b1:1'b0;


assign CMD =(current_state==Init_Load_mode_register_state)?CMD_LOADMODE:
(current_state==activate_state)?CMD_ACTIVE:
(current_state==read_state)?CMD_READ:
(current_state==write_state)?CMD_WRITE:
(current_state==Precharge_state|current_state==Init_PALL_state)?CMD_PRECHARGE:
(current_state==Auto_Refresh_64ms_state|current_state==Init_Auto_Refresh_state)?CMD_AUTO_REFRESH:CMD_NOP;


assign DRAM_DQ=(current_state==write_state)?WR_DATA:{16{1'bz}};		//datasheet page 38,56
//assign DRAM_DQ=(current_state==write_state)?16'hbeef:{16{1'bz}};//debug
assign RD_REQUEST_APPROVED = read_flag_ack;				//tell the host that read is ready. pulse last till net idle state
assign WR_REQUEST_APPROVED = write_flag_ack;  			//tell the host that write is complete. pulse last till net idle state
assign DRAM_CKE=1'b1; 											// has to be high to talk to DRAM. Datasheet page 6
assign DRAM_CS_N=1'b0; 											// has to be low to talk to DRAM. Datasheet page 6
assign {DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N} = CMD;		//DRAM command bits driven by choosen command. order of bits is important. Datasheet page 8
assign {DRAM_UDQM,DRAM_LDQM} = (current_state==write_state | current_state==read_state|current_state==NOP_read_state1|current_state==NOP_read_state2)?2'b00:2'b11; //Datasheet page 8,36,41. Kep low to access all 16 bits.

assign {DRAM_BA,DRAM_ADDR}=(current_state==activate_state)? ADDR[24:10]:								//Select Row & Bankin DRAM
       (current_state==read_state | current_state==write_state)? {ADDR[24:23],3'b000,ADDR[9:0]}:	//Select Column & Bank in DRAM
		 (current_state==Init_PALL_state | current_state==Precharge_state)? {15{1'b1}}:				//make all bits high. A10 must be high. Datasheet page 8
		 (current_state==Init_Load_mode_register_state)? MODE_REG:{15{1'b0}};							//load mode register. Datasheet page 8,21

assign DRAM_CLK=MAX10_CLK2_100_3ns; //connecting clock to DRAM_CLK
assign LEDR=current_state;				//LED to show state machine state

endmodule
