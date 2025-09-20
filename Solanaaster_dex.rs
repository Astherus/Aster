use anchor_lang::prelude::*;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};
use pyth_sdk_solana::{load_price_feed_from_account_info, Price, PriceFeed};
use std::mem::size_of;

declare_id!("EhUtRgu9iEbZXXRpEvDj6n1wnQRjMi2SERDo3c6bmN2c");

#[program]
pub mod aster_dex {
    use super::*;

    pub fn initialize_market(
        ctx: Context<InitializeMarket>,
        market_id: [u8; 32],
        min_collateral: u64,
        max_leverage: u16,
        liquidation_threshold: u16,
    ) -> Result<()> {
        let market = &mut ctx.accounts.market;
        market.admin = ctx.accounts.admin.key();
        market.oracle = ctx.accounts.price_feed.key();
        market.market_id = market_id;
        market.min_collateral = min_collateral;
        market.max_leverage = max_leverage;
        market.liquidation_threshold = liquidation_threshold;
        market.is_active = true;

        Ok(())
    }

    pub fn update_market(
        ctx: Context<UpdateMarket>,
        min_collateral: Option<u64>,
        max_leverage: Option<u16>,
        liquidation_threshold: Option<u16>,
        is_active: Option<bool>,
    ) -> Result<()> {
        let market = &mut ctx.accounts.market;

        if let Some(min_col) = min_collateral {
            market.min_collateral = min_col;
        }

        if let Some(max_lev) = max_leverage {
            require!(max_lev >= 1 && max_lev <= 100, AsterDexError::InvalidLeverage);
            market.max_leverage = max_lev;
        }

        if let Some(liq_threshold) = liquidation_threshold {
            require!(liq_threshold > 0 && liq_threshold < 100, AsterDexError::InvalidLiquidationThreshold);
            market.liquidation_threshold = liq_threshold;
        }

        if let Some(active_state) = is_active {
            market.is_active = active_state;
        }

        Ok(())
    }

    pub fn open_position(
        ctx: Context<OpenPosition>,
        market_id: [u8; 32],
        is_long: bool,
        collateral_amount: u64,
        leverage: u16,
        max_slippage_bps: u16,
    ) -> Result<()> {
        let market = &ctx.accounts.market;
        require!(market.is_active, AsterDexError::MarketInactive);
        require!(leverage >= 1 && leverage <= market.max_leverage, AsterDexError::InvalidLeverage);
        require!(collateral_amount >= market.min_collateral, AsterDexError::InsufficientCollateral);

        // Get price from Pyth oracle
        let price_feed: PriceFeed = load_price_feed_from_account_info(&ctx.accounts.price_feed).unwrap();
        let price: Price = price_feed.get_price_unchecked();
        let current_price = price.price as u64;

        // Transfer collateral from user to vault
        let transfer_ctx = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            Transfer {
                from: ctx.accounts.user_token_account.to_account_info(),
                to: ctx.accounts.vault.to_account_info(),
                authority: ctx.accounts.user.to_account_info(),
            },
        );
        token::transfer(transfer_ctx, collateral_amount)?;

        // Calculate position size
        let position_size = collateral_amount as u128 * leverage as u128;

        // Create position account
        let position = &mut ctx.accounts.position;
        position.trader = ctx.accounts.user.key();
        position.market_id = market_id;
        position.collateral = collateral_amount;
        position.size = position_size as u64;
        position.is_long = is_long;
        position.entry_price = current_price;
        position.leverage = leverage;
        position.open_time = Clock::get()?.unix_timestamp;
        position.collateral_mint = ctx.accounts.collateral_mint.key();
        position.last_funding_index = 0; // In a real implementation, get the current funding index

        emit!(PositionOpened {
            position: ctx.accounts.position.key(),
            trader: ctx.accounts.user.key(),
            market_id,
            is_long,
            collateral_amount,
            position_size: position_size as u64,
            entry_price: current_price,
            leverage,
        });

        Ok(())
    }

    pub fn close_position(ctx: Context<ClosePosition>) -> Result<()> {
        let position = &ctx.accounts.position;
        require!(position.size > 0, AsterDexError::InvalidPosition);

        // Get price from Pyth oracle
        let price_feed: PriceFeed = load_price_feed_from_account_info(&ctx.accounts.price_feed).unwrap();
        let price: Price = price_feed.get_price_unchecked();
        let current_price = price.price as u64;

        // Calculate PnL
        let (pnl, fee) = calculate_pnl(position, current_price);

        // Calculate return amount
        let return_amount: u64;
        if pnl >= 0 {
            return_amount = position.collateral + pnl as u64 - fee;
        } else {
            let remaining = position.collateral as i64 + pnl - fee as i64;
            return_amount = if remaining > 0 { remaining as u64 } else { 0 };
        }

        // Transfer funds back to user if any
        if return_amount > 0 {
            let seeds = &[
                b"vault".as_ref(),
                ctx.accounts.market.to_account_info().key.as_ref(),
                &[ctx.accounts.market.bump],
            ];
            let signer = &[&seeds[..]];
            
            let transfer_ctx = CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.vault.to_account_info(),
                    to: ctx.accounts.user_token_account.to_account_info(),
                    authority: ctx.accounts.vault.to_account_info(),
                },
                signer,
            );
            token::transfer(transfer_ctx, return_amount)?;
        }

        emit!(PositionClosed {
            position: ctx.accounts.position.key(),
            trader: position.trader,
            close_price: current_price,
            pnl,
            fee,
        });

        // Close the position account
        let position_account_info = ctx.accounts.position.to_account_info();
        let destination = ctx.accounts.user.to_account_info();
        
        let dest_starting_lamports = destination.lamports();
        **destination.lamports.borrow_mut() = dest_starting_lamports.checked_add(position_account_info.lamports()).unwrap();
        **position_account_info.lamports.borrow_mut() = 0;
        
        Ok(())
    }

    pub fn liquidate_position(ctx: Context<LiquidatePosition>) -> Result<()> {
        let position = &ctx.accounts.position;
        require!(position.size > 0, AsterDexError::InvalidPosition);

        // Get price from Pyth oracle
        let price_feed: PriceFeed = load_price_feed_from_account_info(&ctx.accounts.price_feed).unwrap();
        let price: Price = price_feed.get_price_unchecked();
        let current_price = price.price as u64;

        // Calculate PnL
        let (pnl, _) = calculate_pnl(position, current_price);

        // Check if position is liquidatable
        let equity_percentage = ((position.collateral as i64 + pnl) * 100) / position.collateral as i64;
        let market = &ctx.accounts.market;
        
        require!(
            equity_percentage <= market.liquidation_threshold as i64,
            AsterDexError::CannotLiquidateYet
        );

        // Calculate liquidator reward (e.g., 3% of remaining collateral)
        let liquidation_fee = position.collateral * 3 / 100;

        // Transfer reward to liquidator
        if liquidation_fee > 0 {
            let seeds = &[
                b"vault".as_ref(),
                ctx.accounts.market.to_account_info().key.as_ref(),
                &[ctx.accounts.market.bump],
            ];
            let signer = &[&seeds[..]];
            
            let transfer_ctx = CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.vault.to_account_info(),
                    to: ctx.accounts.liquidator_token_account.to_account_info(),
                    authority: ctx.accounts.vault.to_account_info(),
                },
                signer,
            );
            token::transfer(transfer_ctx, liquidation_fee)?;
        }

        emit!(PositionLiquidated {
            position: ctx.accounts.position.key(),
            trader: position.trader,
            liquidator: ctx.accounts.liquidator.key(),
            liquidation_price: current_price,
            fee: liquidation_fee,
        });

        // Close the position account
        let position_account_info = ctx.accounts.position.to_account_info();
        let destination = ctx.accounts.liquidator.to_account_info();
        
        let dest_starting_lamports = destination.lamports();
        **destination.lamports.borrow_mut() = dest_starting_lamports.checked_add(position_account_info.lamports()).unwrap();
        **position_account_info.lamports.borrow_mut() = 0;
        
        Ok(())
    }

    pub fn update_funding(ctx: Context<UpdateFunding>, new_funding_index: u64) -> Result<()> {
        let market = &mut ctx.accounts.market;
        require!(market.admin == ctx.accounts.admin.key(), AsterDexError::Unauthorized);
        
        market.last_funding_index = new_funding_index;
        market.last_funding_time = Clock::get()?.unix_timestamp;
        
        Ok(())
    }
}

// Helper function to calculate PnL
fn calculate_pnl(position: &Position, current_price: u64) -> (i64, u64) {
    let price_delta = if position.is_long {
        current_price as i64 - position.entry_price as i64
    } else {
        position.entry_price as i64 - current_price as i64
    };
    
    let pnl_percentage = (price_delta * 10000) / position.entry_price as i64;
    let raw_pnl = (pnl_percentage * position.size as i64) / 10000;
    
    // Calculate trading fee (0.1% of position size)
    let fee = (position.size * 10) / 10000;
    
    (raw_pnl, fee)
}

#[derive(Accounts)]
#[instruction(market_id: [u8; 32])]
pub struct InitializeMarket<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    
    #[account(
        init,
        payer = admin,
        space = 8 + size_of::<Market>(),
        seeds = [b"market", &market_id],
        bump
    )]
    pub market: Account<'info, Market>,
    
    /// CHECK: This is the Pyth price feed account
    pub price_feed: AccountInfo<'info>,
    
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateMarket<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    
    #[account(
        mut,
        constraint = market.admin == admin.key() @ AsterDexError::Unauthorized
    )]
    pub market: Account<'info, Market>,
}

#[derive(Accounts)]
#[instruction(market_id: [u8; 32])]
pub struct OpenPosition<'info> {
    #[account(mut)]
    pub user: Signer<'info>,
    
    #[account(
        mut,
        seeds = [b"market", &market_id],
        bump = market.bump,
        constraint = market.is_active @ AsterDexError::MarketInactive
    )]
    pub market: Account<'info, Market>,
    
    #[account(
        init,
        payer = user,
        space = 8 + size_of::<Position>(),
        seeds = [b"position", user.key().as_ref(), &market_id, &Clock::get().unwrap().unix_timestamp.to_le_bytes()],
        bump
    )]
    pub position: Account<'info, Position>,
    
    #[account(
        mut,
        constraint = user_token_account.owner == user.key() @ AsterDexError::InvalidTokenAccount,
        constraint = user_token_account.mint == collateral_mint.key() @ AsterDexError::InvalidMint
    )]
    pub user_token_account: Account<'info, TokenAccount>,
    
    #[account(
        mut,
        seeds = [b"vault", market.key().as_ref()],
        bump = market.bump
    )]
    pub vault: Account<'info, TokenAccount>,
    
    pub collateral_mint: Account<'info, Mint>,
    
    /// CHECK: This is the Pyth price feed account
    #[account(constraint = market.oracle == price_feed.key() @ AsterDexError::InvalidOracle)]
    pub price_feed: AccountInfo<'info>,
    
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
pub struct ClosePosition<'info> {
    #[account(mut)]
    pub user: Signer<'info>,
    
    #[account(
        mut,
        close = user,
        constraint = position.trader == user.key() @ AsterDexError::Unauthorized
    )]
    pub position: Account<'info, Position>,
    
    #[account(
        seeds = [b"market", &position.market_id],
        bump = market.bump
    )]
    pub market: Account<'info, Market>,
    
    #[account(
        mut,
        constraint = user_token_account.owner == user.key() @ AsterDexError::InvalidTokenAccount,
        constraint = user_token_account.mint == position.collateral_mint @ AsterDexError::InvalidMint
    )]
    pub user_token_account: Account<'info, TokenAccount>,
    
    #[account(
        mut,
        seeds = [b"vault", market.key().as_ref()],
        bump = market.bump
    )]
    pub vault: Account<'info, TokenAccount>,
    
    /// CHECK: This is the Pyth price feed account
    #[account(constraint = market.oracle == price_feed.key() @ AsterDexError::InvalidOracle)]
    pub price_feed: AccountInfo<'info>,
    
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct LiquidatePosition<'info> {
    #[account(mut)]
    pub liquidator: Signer<'info>,
    
    #[account(mut)]
    /// CHECK: Position owner, doesn't need to sign for liquidation
    pub trader: AccountInfo<'info>,
    
    #[account(
        mut,
        close = liquidator,
        constraint = position.trader == trader.key() @ AsterDexError::InvalidPosition
    )]
    pub position: Account<'info, Position>,
    
    #[account(
        seeds = [b"market", &position.market_id],
        bump = market.bump
    )]
    pub market: Account<'info, Market>,
    
    #[account(
        mut,
        constraint = liquidator_token_account.owner == liquidator.key() @ AsterDexError::InvalidTokenAccount,
        constraint = liquidator_token_account.mint == position.collateral_mint @ AsterDexError::InvalidMint
    )]
    pub liquidator_token_account: Account<'info, TokenAccount>,
    
    #[account(
        mut,
        seeds = [b"vault", market.key().as_ref()],
        bump = market.bump
    )]
    pub vault: Account<'info, TokenAccount>,
    
    /// CHECK: This is the Pyth price feed account
    #[account(constraint = market.oracle == price_feed.key() @ AsterDexError::InvalidOracle)]
    pub price_feed: AccountInfo<'info>,
    
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateFunding<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    
    #[account(
        mut,
        constraint = market.admin == admin.key() @ AsterDexError::Unauthorized
    )]
    pub market: Account<'info, Market>,
}

#[account]
pub struct Market {
    pub admin: Pubkey,
    pub oracle: Pubkey,
    pub market_id: [u8; 32],
    pub min_collateral: u64,
    pub max_leverage: u16,
    pub liquidation_threshold: u16,
    pub is_active: bool,
    pub last_funding_index: u64,
    pub last_funding_time: i64,
    pub bump: u8,
}

#[account]
pub struct Position {
    pub trader: Pubkey,
    pub market_id: [u8; 32],
    pub collateral: u64,
    pub size: u64,
    pub is_long: bool,
    pub entry_price: u64,
    pub leverage: u16,
    pub open_time: i64,
    pub collateral_mint: Pubkey,
    pub last_funding_index: u64,
}

#[error_code]
pub enum AsterDexError {
    #[msg("Market is not active")]
    MarketInactive,
    #[msg("Invalid leverage")]
    InvalidLeverage,
    #[msg("Insufficient collateral")]
    InsufficientCollateral,
    #[msg("Invalid position")]
    InvalidPosition,
    #[msg("Cannot liquidate yet")]
    CannotLiquidateYet,
    #[msg("Unauthorized action")]
    Unauthorized,
    #[msg("Invalid token account")]
    InvalidTokenAccount,
    #[msg("Invalid mint")]
    InvalidMint,
    #[msg("Invalid oracle")]
    InvalidOracle,
    #[msg("Invalid liquidation threshold")]
    InvalidLiquidationThreshold,
}

#[event]
pub struct PositionOpened {
    #[index]
    pub position: Pubkey,
    #[index]
    pub trader: Pubkey,
    pub market_id: [u8; 32],
    pub is_long: bool,
    pub collateral_amount: u64,
    pub position_size: u64,
    pub entry_price: u64,
    pub leverage: u16,
}

#[event]
pub struct PositionClosed {
    #[index]
    pub position: Pubkey,
    #[index]
    pub trader: Pubkey,
    pub close_price: u64,
    pub pnl: i64,
    pub fee: u64,
}

#[event]
pub struct PositionLiquidated {
    #[index]
    pub position: Pubkey,
    #[index]
    pub trader: Pubkey,
    pub liquidator: Pubkey,
    pub liquidation_price: u64,
    pub fee: u64,
}
