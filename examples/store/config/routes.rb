Rails.application.routes.draw do
  resources :products, only: %i[index show create update] do
    collection do
      get :stats
      get :low_stock
      post :deactivate_sold_out
      post :double
    end
    member do
      post :restock
      get :quote
      get :availability
    end
  end
  resources :orders, only: %i[show create] do
    member do
      post :add_item
      post :place
      post :reopen
      get :summary
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
