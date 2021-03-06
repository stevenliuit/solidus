require 'spec_helper'

RSpec.feature "Quantity Promotions" do
  given(:action) do
    Spree::Promotion::Actions::CreateQuantityAdjustments.create(
      calculator: calculator,
      preferred_group_size: 2
    )
  end

  given(:promotion) { FactoryGirl.create(:promotion, code: "PROMO") }
  given(:calculator) { FactoryGirl.create(:calculator, preferred_amount: 5) }

  background do
    create(:store)
    FactoryGirl.create(:product, name: "DL-44")
    FactoryGirl.create(:product, name: "E-11")
    promotion.actions << action

    visit spree.root_path
    click_link "DL-44"
    click_button "Add To Cart"
  end

  scenario "adding and removing items from the cart" do
    # Add the code with too few items.
    fill_in "Coupon code", with: "PROMO"
    click_button "Update"
    expect(page).to have_content("The coupon code was successfully applied to your order")

    # Add another item to our cart.
    visit spree.root_path
    click_link "DL-44"
    click_button "Add To Cart"
    within("#cart_adjustments") do
      expect(page).to have_content("-$10.00")
    end

    # Applying the code again should fail.
    fill_in "Coupon code", with: "PROMO"
    click_button "Update"
    expect(page).to have_content("The coupon code has already been applied to this order")
    fill_in "Coupon code", with: "" # clear the failed code

    # Reduce quantity by 1, making promotion not apply.
    fill_in "order_line_items_attributes_0_quantity", with: 1
    click_button "Update"
    expect(page).to_not have_content("#cart_adjustments")

    # Bump quantity to 3, making promotion apply "once."
    fill_in "order_line_items_attributes_0_quantity", with: 3
    click_button "Update"
    within("#cart_adjustments") do
      expect(page).to have_content("-$10.00")
    end

    # Bump quantity to 4, making promotion apply "twice."
    fill_in "order_line_items_attributes_0_quantity", with: 4
    click_button "Update"
    within("#cart_adjustments") do
      expect(page).to have_content("-$20.00")
    end
  end

  # Catches an earlier issue with quantity calculation.
  scenario "adding odd numbers of items to the cart" do
    # Bump quantity to 3
    fill_in "order_line_items_attributes_0_quantity", with: 3
    click_button "Update"

    # Apply the promo code and see a $10 discount (for 2 of the 3 items)
    fill_in "Coupon code", with: "PROMO"
    click_button "Update"
    expect(page).to have_content("The coupon code was successfully applied to your order")
    within("#cart_adjustments") do
      expect(page).to have_content("-$10.00")
    end

    # Add a different product to our cart with quantity of 2.
    visit spree.root_path
    click_link "E-11"
    fill_in "quantity", with: "2"
    click_button "Add To Cart"

    # We now have 5 items total, so discount should increase.
    within("#cart_adjustments") do
      expect(page).to have_content("-$20.00")
    end
  end

  context "with a group size of 3" do
    given(:action) do
      Spree::Promotion::Actions::CreateQuantityAdjustments.create(
        calculator: calculator,
        preferred_group_size: 3
      )
    end

    background { FactoryGirl.create(:product, name: "DC-15A") }

    scenario "odd number of changes to quantities" do
      fill_in "order_line_items_attributes_0_quantity", with: 3
      click_button "Update"

      # Apply the promo code and see a $15 discount
      fill_in "Coupon code", with: "PROMO"
      click_button "Update"
      expect(page).to have_content("The coupon code was successfully applied to your order")
      within("#cart_adjustments") do
        expect(page).to have_content("-$15.00")
      end

      # Add two different products to our cart
      visit spree.root_path
      click_link "E-11"
      click_button "Add To Cart"
      within("#cart_adjustments") do
        expect(page).to have_content("-$15.00")
      end

      # Reduce quantity of first item to 2
      fill_in "order_line_items_attributes_0_quantity", with: 2
      click_button "Update"
      within("#cart_adjustments") do
        expect(page).to have_content("-$15.00")
      end
    end
  end
end
