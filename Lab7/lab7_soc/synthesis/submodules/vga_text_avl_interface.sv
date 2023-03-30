/************************************************************************

Avalon-MM Interface VGA Text mode display

Register Map:
0x000-0x0257 : VRAM, 80x30 (2400 byte, 600 word) raster order (first column then row)
0x258        : control register

VRAM Format:
X->
[ 31  30-24][ 23  22-16][ 15  14-8 ][ 7    6-0 ]
[IV3][CODE3][IV2][CODE2][IV1][CODE1][IV0][CODE0]

IVn = Draw inverse glyph
CODEn = Glyph code from IBM codepage 437

Control Register Format:
[[31-25][24-21][20-17][16-13][ 12-9][ 8-5 ][ 4-1 ][   0    ] 
[[RSVD ][FGD_R][FGD_G][FGD_B][BKG_R][BKG_G][BKG_B][RESERVED]

VSYNC signal = bit which flips on every Vsync (time for new frame), used to synchronize software
BKG_R/G/B = Background color, flipped with foreground when IVn bit is set
FGD_R/G/B = Foreground color, flipped with background when Inv bit is set

************************************************************************/
`define NUM_REGS 601 //80*30 characters / 4 characters per register
`define CTRL_REG 600 //index of control register

module vga_text_avl_interface (
	// Avalon Clock Input, note this clock is also used for VGA, so this must be 50Mhz
	// We can put a clock divider here in the future to make this IP more generalizable
	input logic CLK,
	
	// Avalon Reset Input
	input logic RESET,
	
	// Avalon-MM Slave Signals
	input  logic AVL_READ,						// Avalon-MM Read
	input  logic AVL_WRITE,						// Avalon-MM Write
	input  logic AVL_CS,						// Avalon-MM Chip Select
	input  logic [3:0] AVL_BYTE_EN,				// Avalon-MM Byte Enable
	input  logic [9:0] AVL_ADDR,				// Avalon-MM Address
	input  logic [31:0] AVL_WRITEDATA,			// Avalon-MM Write Data
	output logic [31:0] AVL_READDATA,			// Avalon-MM Read Data
	
	// Exported Conduit (mapped to VGA port - make sure you export in Platform Designer)
	output logic [3:0]  red, green, blue,		// VGA color channels (mapped to output pins in top-level)
	output logic hs, vs							// VGA HS/VS
);

logic [31:0] LOCAL_REG [0:601];					// Registers
// put other local variables here
logic [7:0] data;								// Output for font_rom

logic pixel_clk, blank, sync;					// Outputs for vga_controller
logic [9:0] DrawX, DrawY;	


// Declare submodules e.g. VGA controller, ROMS, etc
vga_controller vga_controller (.Clk(CLK), .Reset(RESET), .hs(hs), .vs(vs), .pixel_clk(pixel_clk), .blank(blank), .sync(sync), .DrawX(DrawX), .DrawY(DrawY));
font_rom fm(.addr(row_idx), .data(data));		// row_idx is calculated below


// Read and write from AVL interface to register block, note that READ waitstate = 1, so this should be in always_ff
always_ff @(posedge CLK) begin
	if (RESET)
		begin
			for (int i = 0; i < `NUM_REGS; i++)
					LOCAL_REG[i] <= 32'b0;	
		end
	else if (AVL_READ && AVL_CS)
		//index local registers we take from local avalon bus 
		AVL_READDATA <= LOCAL_REG[AVL_ADDR];
	else if(AVL_WRITE && AVL_CS)
		begin
			unique case (AVL_BYTE_EN)
				4'b1111 : LOCAL_REG[AVL_ADDR] 		 <= AVL_WRITEDATA;
				4'b1100 : LOCAL_REG[AVL_ADDR][31:16] <= AVL_WRITEDATA[31:16]; 
				4'b0011 : LOCAL_REG[AVL_ADDR][15:0]  <= AVL_WRITEDATA[15:0];
				4'b1000 : LOCAL_REG[AVL_ADDR][31:24] <= AVL_WRITEDATA[31:24]; 
				4'b0100 : LOCAL_REG[AVL_ADDR][23:16] <= AVL_WRITEDATA[23:16];
				4'b0010 : LOCAL_REG[AVL_ADDR][15:8]  <= AVL_WRITEDATA[15:8];	
				4'b0001 : LOCAL_REG[AVL_ADDR][7:0]   <= AVL_WRITEDATA[7:0];
			endcase
		end
end


// DRAWING PORTION

// Find the block you are in, essentially breaking the screen up into 80x30 chunks
logic [7:0] block_X;
assign block_X = DrawX[9:3];							// Divide by 8
logic [6:0] block_Y;
assign block_Y = DrawY[9:4]; 							// Divide by 16


// Find the character address as well as the register it's in
logic [31:0] char_address;
assign char_address = block_Y * 80 + block_X; 		// Location of character on screen
logic [31:0] register;
assign register = char_address[11:2]; 				// Location of register on screen
logic [1:0]  char_num;
assign char_num = char_address[1:0]; 				// Location of the character relative to the register


// Determine the ascii code of the sprite
logic [7:0] fm_code;
always_comb
	begin
		fm_code = 0; 
		if(char_num == 2'b00)									// 0th character
			fm_code = LOCAL_REG[register][7:0];
		if(char_num == 2'b01)									// 1st character
			fm_code = LOCAL_REG[register][15:8];				
		if(char_num == 2'b10)									// 2nd character
			fm_code = LOCAL_REG[register][23:16];				
		if(char_num == 2'b11)									// 3rd character
			fm_code = LOCAL_REG[register][31:24];		
	end		


// Find the data for the sprite you want to draw
logic [10:0] row_idx;
assign row_idx = fm_code[6:0]*16 + DrawY[3:0];
logic [2:0]	 col_idx;
assign col_idx = 7 - DrawX[2:0];

logic color_bit; 
assign color_bit = data[col_idx];


// Color based on blank, inverse, foreground, background
always_ff @(posedge pixel_clk)
begin
	if (blank == 1'b0)									// blank is active low, when it is 0 default to black, otherwise just continue with the code
		begin
			red 	<=	4'b0000;
			green <=	4'b0000;
			blue 	<=	4'b0000;
		end
	else if (fm_code[7] ^ color_bit == 1'b1) 			// draw foreground
		begin
			red 	<=	LOCAL_REG[601][24:21];
			green <= LOCAL_REG[601][20:17];
			blue 	<=	LOCAL_REG[601][16:13];
		end
	else if (fm_code[7] ^ color_bit == 1'b0) 			// draw background
		begin
			red 	<=	LOCAL_REG[601][12:9];
			green <=	LOCAL_REG[601][8:5];
			blue 	<=	LOCAL_REG[601][4:1];
		end
end

endmodule
